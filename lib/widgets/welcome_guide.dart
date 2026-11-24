import 'package:flutter/material.dart';

const _steps = [
  (
    icon: Icons.add_to_photos_outlined,
    title: 'Welcome to Kinesis',
    body:
        'Kinesis copies photos and videos from a camera card or folder into '
        'your library, verifies every copy with SHA-256, and can then move the '
        'source files to Trash.',
  ),
  (
    icon: Icons.folder_outlined,
    title: 'Set your library',
    body:
        'Use Set library in the toolbar to choose the folder your media is '
        'imported into. Kinesis never copies a file that is already in it.',
  ),
  (
    icon: Icons.folder_open,
    title: 'Choose a source',
    body:
        'Pick a source folder, or click a connected camera card in the quick '
        'picks. Kinesis scans it and pairs JPEG and RAW files with the same '
        'name into one shot.',
  ),
  (
    icon: Icons.grid_view_outlined,
    title: 'Review your shots',
    body:
        'Step through shots with the arrow keys, or switch to grid view to '
        'select several at once. Decide per shot: A keeps both, S keeps the '
        'JPEG, D keeps the RAW, F deletes both. Kinesis leaves shots without '
        'a decision alone. Change the shortcuts in Settings.',
  ),
  (
    icon: Icons.fact_check_outlined,
    title: 'Review the plan and import',
    body:
        'Open the ingest plan with the button in the bottom right corner. '
        'Check what Kinesis will copy and move to Trash, then confirm.',
  ),
  (
    icon: Icons.help_outline,
    title: 'Replay this guide',
    body:
        'The Help menu in the toolbar replays this guide and links to the '
        'documentation on GitHub.',
  ),
];

class WelcomeGuide extends StatefulWidget {
  const WelcomeGuide({super.key});

  @override
  State<WelcomeGuide> createState() => _WelcomeGuideState();
}

class _WelcomeGuideState extends State<WelcomeGuide> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    final step = _steps[_step];
    final last = _step == _steps.length - 1;
    return AlertDialog(
      icon: Icon(step.icon, size: 40),
      title: Text(step.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(step.body, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Text(
              '${_step + 1} of ${_steps.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        if (!last)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Skip'),
          ),
        if (_step > 0)
          TextButton(
            onPressed: () => setState(() => _step--),
            child: const Text('Back'),
          ),
        FilledButton(
          onPressed: last
              ? () => Navigator.pop(context)
              : () => setState(() => _step++),
          child: Text(last ? 'Get started' : 'Next'),
        ),
      ],
    );
  }
}
