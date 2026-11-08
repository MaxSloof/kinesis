import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/capture_date.dart';
import '../domain/import_options.dart';

enum _DateMode { none, fixed, shift }

/// Per-import choices: a shoot name for the `{shoot}` template token, and an
/// override or shift of every capture date to fix a wrong camera clock or time
/// zone. The result applies to one import only.
class ImportOptionsDialog extends StatefulWidget {
  const ImportOptionsDialog({super.key, required this.initial});

  final ImportOptions initial;

  @override
  State<ImportOptionsDialog> createState() => _ImportOptionsDialogState();
}

class _ImportOptionsDialogState extends State<ImportOptionsDialog> {
  late _DateMode _mode;
  DateTime? _fixed;
  bool _negative = false;
  late final TextEditingController _shoot;
  late final TextEditingController _hours;
  late final TextEditingController _minutes;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial.dateAdjustment;
    _shoot = TextEditingController(text: widget.initial.shoot);
    _fixed = initial.fixed;
    _mode = initial.fixed != null
        ? _DateMode.fixed
        : initial.shift != Duration.zero
        ? _DateMode.shift
        : _DateMode.none;
    _negative = initial.shift.isNegative;
    final total = initial.shift.inMinutes.abs();
    _hours = TextEditingController(text: '${total ~/ 60}');
    _minutes = TextEditingController(text: '${total % 60}');
  }

  @override
  void dispose() {
    _shoot.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = _fixed ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !mounted) return;
    setState(
      () => _fixed = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  CaptureDateAdjustment? get _adjustment => switch (_mode) {
    _DateMode.none => CaptureDateAdjustment.none,
    _DateMode.fixed =>
      _fixed == null ? null : CaptureDateAdjustment(fixed: _fixed),
    _DateMode.shift => CaptureDateAdjustment.shiftBy(
      negative: _negative,
      hours: int.tryParse(_hours.text) ?? 0,
      minutes: int.tryParse(_minutes.text) ?? 0,
    ),
  };

  ImportOptions? get _result {
    final adjustment = _adjustment;
    return adjustment == null
        ? null
        : ImportOptions(dateAdjustment: adjustment, shoot: _shoot.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final fixed = _fixed;
    return AlertDialog(
      title: const Text('Import options'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('These apply to this import only and are not saved.'),
            const SizedBox(height: 16),
            TextField(
              controller: _shoot,
              decoration: const InputDecoration(
                labelText: 'Shoot name',
                helperText:
                    'Used by the {shoot} template token; leave empty to omit',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Capture dates',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Changes the folder dates, the dates shown here and the '
              'modified time of the copies.',
            ),
            const SizedBox(height: 12),
            SegmentedButton<_DateMode>(
              segments: const [
                ButtonSegment(value: _DateMode.none, label: Text('None')),
                ButtonSegment(value: _DateMode.fixed, label: Text('Set date')),
                ButtonSegment(value: _DateMode.shift, label: Text('Shift')),
              ],
              selected: {_mode},
              onSelectionChanged: (value) =>
                  setState(() => _mode = value.single),
            ),
            const SizedBox(height: 16),
            if (_mode == _DateMode.fixed)
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  fixed == null
                      ? 'Choose date and time'
                      : CaptureDateAdjustment(fixed: fixed).description!,
                ),
              ),
            if (_mode == _DateMode.shift)
              Row(
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('+')),
                      ButtonSegment(value: true, label: Text('−')),
                    ],
                    selected: {_negative},
                    onSelectionChanged: (value) =>
                        setState(() => _negative = value.single),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _hours,
                      decoration: const InputDecoration(labelText: 'Hours'),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(3),
                      ],
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _minutes,
                      decoration: const InputDecoration(labelText: 'Minutes'),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(2),
                      ],
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _result == null
              ? null
              : () => Navigator.pop(context, _result),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
