import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'domain/media.dart';
import 'services/media_service.dart';
import 'shortcuts.dart';

void main() => runApp(const KinesisApp());

class KinesisApp extends StatelessWidget {
  const KinesisApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Kinesis',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b67)),
      useMaterial3: true,
    ),
    home: const KinesisHome(),
  );
}

class KinesisHome extends StatefulWidget {
  const KinesisHome({super.key});

  @override
  State<KinesisHome> createState() => _KinesisHomeState();
}

class _KinesisHomeState extends State<KinesisHome> {
  final _media = MediaService();
  final _trash = TrashService();
  final _decisions = <int, ReviewDecision>{};
  List<ReviewItem> _items = [];
  LocalStore? _store;
  Set<String> _existingHashes = {};
  List<ImportedAsset> _libraryAssets = [];
  String? _library;
  String _template = '{year}/{year}-{month}-{day}';
  Map<ReviewDecision, String> _shortcuts = {
    ReviewDecision.keepBoth: 'A',
    ReviewDecision.keepJpeg: 'S',
    ReviewDecision.keepCr3: 'D',
    ReviewDecision.deleteBoth: 'F',
  };
  int _current = 0;
  bool _scanning = false;
  bool _gridMode = false;
  final _selectedItems = <int>{};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final support = await getApplicationSupportDirectory();
    final store = LocalStore(File(path.join(support.path, 'index.json')));
    Map<String, dynamic> state;
    try {
      state = await store.read();
    } on FormatException {
      state = {};
    }
    if (!mounted) return;
    setState(() {
      _store = store;
      _library = state['library'] as String?;
      _template = state['template'] as String? ?? _template;
      final savedShortcuts = state['shortcuts'] as Map<String, dynamic>?;
      if (savedShortcuts != null) {
        _shortcuts = {
          for (final decision in ReviewDecision.values)
            decision:
                savedShortcuts[decision.name] as String? ??
                _shortcuts[decision]!,
        };
      }
      _existingHashes = ((state['hashes'] as List<dynamic>?) ?? [])
          .cast<String>()
          .toSet();
      _libraryAssets = ((state['assets'] as List<dynamic>?) ?? [])
          .map((asset) => ImportedAsset.fromJson(asset as Map<String, dynamic>))
          .toList();
    });
  }

  Future<void> _saveSettings() =>
      _store?.write({
        'library': _library,
        'hashes': _existingHashes.toList(),
        'assets': _libraryAssets.map((asset) => asset.toJson()).toList(),
        'template': _template,
        'shortcuts': {
          for (final entry in _shortcuts.entries) entry.key.name: entry.value,
        },
      }) ??
      Future.value();

  Future<void> _chooseLibrary() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose your Kinesis media library',
    );
    if (selected == null) return;
    setState(() => _library = selected);
    await _saveSettings();
  }

  Future<void> _chooseSource() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a camera card or source folder',
    );
    if (selected == null) return;
    setState(() => _scanning = true);
    try {
      final scanned = await _media.scan(selected);
      if (mounted) {
        setState(() {
          _items = scanned;
          _decisions.clear();
          _selectedItems.clear();
          _current = 0;
          _gridMode = false;
        });
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not scan source: ${error.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _decide(ReviewDecision decision) {
    if (_items.isEmpty) return;
    setState(() {
      if (_gridMode && _selectedItems.isNotEmpty) {
        for (final index in _selectedItems) {
          _decisions[index] = decision;
        }
        return;
      }
      _decisions[_current] = decision;
      if (_current < _items.length - 1) _current++;
    });
  }

  Future<void> _confirm() async {
    if (_library == null) {
      await _chooseLibrary();
      if (_library == null) return;
    }
    const planner = ImportPlanner();
    final plan = _decisions.entries.fold(
      const ImportPlan(toImport: [], toDelete: [], skipped: []),
      (total, entry) {
        final next = planner.plan(_items[entry.key], entry.value);
        return ImportPlan(
          toImport: [...total.toImport, ...next.toImport],
          toDelete: [...total.toDelete, ...next.toDelete],
          skipped: [...total.skipped, ...next.skipped],
        );
      },
    );
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm ingest plan'),
        content: Text(
          '${plan.toImport.length} files will be checked, copied, and SHA-256 verified.\n'
          'Already-imported files will be skipped before copying.\n'
          '${plan.toDelete.length} source files will move to Trash.\n\n'
          'Unreviewed items are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    final knownHashes = <String>{..._existingHashes};
    final importedAssets = <ImportedAsset>[];
    var skipped = 0;
    try {
      for (final file in plan.toImport) {
        final sourceHash = await _media.hashFile(file.path);
        if (!knownHashes.add(sourceHash)) {
          skipped++;
          continue;
        }
        importedAssets.add(
          await _media.copyAndVerify(
            file.withHash(sourceHash),
            _library!,
            _template,
          ),
        );
      }
      _existingHashes.addAll(importedAssets.map((asset) => asset.hash));
      _libraryAssets.addAll(importedAssets);
      await _saveSettings();
      for (final file in plan.toDelete) {
        if (await File(file.path).exists()) {
          await _trash.moveToTrash(file.path);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ingest completed. $skipped duplicates skipped.'),
          ),
        );
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ingest stopped: ${error.message}')),
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not move a source file to Trash: ${error.message}',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (final decision in ReviewDecision.values)
        SingleActivator(logicalKeyForShortcut(_shortcuts[decision]!)): () =>
            _decide(decision),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Kinesis'),
          actions: [
            IconButton(
              onPressed: _showSettings,
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
            ),
            IconButton(
              onPressed: _showLibrary,
              icon: const Icon(Icons.photo_library_outlined),
              tooltip: 'Library',
            ),
            if (_items.isNotEmpty)
              IconButton(
                onPressed: () => setState(() {
                  _gridMode = !_gridMode;
                  _selectedItems.clear();
                }),
                icon: Icon(
                  _gridMode
                      ? Icons.fullscreen_outlined
                      : Icons.grid_view_outlined,
                ),
                tooltip: _gridMode ? 'Single image review' : 'Grid review',
              ),
            TextButton.icon(
              onPressed: _chooseLibrary,
              icon: const Icon(Icons.folder_outlined),
              label: Text(_library == null ? 'Set library' : 'Library set'),
            ),
          ],
        ),
        body: _items.isEmpty
            ? _welcome()
            : (_gridMode ? _reviewGrid() : _review()),
        floatingActionButton: _items.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: _decisions.isEmpty ? null : _confirm,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text('Review plan (${_decisions.length})'),
              ),
      ),
    ),
  );

  Widget _welcome() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.add_to_photos_outlined, size: 64),
        const SizedBox(height: 16),
        const Text(
          'Ingest media you can trust',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Review camera files, verify copies, then clean the source.',
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _scanning ? null : _chooseSource,
          icon: const Icon(Icons.folder_open),
          label: Text(_scanning ? 'Scanning...' : 'Choose source folder'),
        ),
      ],
    ),
  );

  Widget _review() {
    final item = _items[_current];
    final preview =
        item.jpeg ??
        (item.single?.kind == MediaKind.image ? item.single : null);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_current + 1} of ${_items.length}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: Center(
                child: preview == null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.perm_media_outlined, size: 96),
                          const SizedBox(height: 16),
                          Text(
                            item.label,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            item.isPair
                                ? 'JPEG + CR3 pair'
                                : 'Preview unavailable',
                          ),
                        ],
                      )
                    : Image.file(
                        File(preview.path),
                        fit: BoxFit.contain,
                        // Camera JPEGs are commonly 6000px wide. Decode only
                        // enough pixels for a desktop review surface.
                        cacheWidth: 1600,
                        errorBuilder: (_, _, _) => Text(item.label),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(item.label, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              _action(
                _shortcuts[ReviewDecision.keepBoth]!,
                'Keep both',
                ReviewDecision.keepBoth,
              ),
              _action(
                _shortcuts[ReviewDecision.keepJpeg]!,
                'Keep JPEG',
                ReviewDecision.keepJpeg,
              ),
              _action(
                _shortcuts[ReviewDecision.keepCr3]!,
                'Keep CR3',
                ReviewDecision.keepCr3,
              ),
              _action(
                _shortcuts[ReviewDecision.deleteBoth]!,
                'Delete both',
                ReviewDecision.deleteBoth,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reviewGrid() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Row(
          children: [
            Text(
              '${_selectedItems.length} selected',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(
                () => _selectedItems.addAll(
                  List.generate(_items.length, (index) => index),
                ),
              ),
              child: const Text('Select all'),
            ),
            TextButton(
              onPressed: () => setState(_selectedItems.clear),
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          itemCount: _items.length,
          itemBuilder: (_, index) => _gridTile(index),
        ),
      ),
      if (_selectedItems.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              _action(
                _shortcuts[ReviewDecision.keepBoth]!,
                'Keep both',
                ReviewDecision.keepBoth,
              ),
              _action(
                _shortcuts[ReviewDecision.keepJpeg]!,
                'Keep JPEG',
                ReviewDecision.keepJpeg,
              ),
              _action(
                _shortcuts[ReviewDecision.keepCr3]!,
                'Keep CR3',
                ReviewDecision.keepCr3,
              ),
              _action(
                _shortcuts[ReviewDecision.deleteBoth]!,
                'Delete both',
                ReviewDecision.deleteBoth,
              ),
            ],
          ),
        ),
    ],
  );

  Widget _gridTile(int index) {
    final item = _items[index];
    final preview =
        item.jpeg ??
        (item.single?.kind == MediaKind.image ? item.single : null);
    final selected = _selectedItems.contains(index);
    final decision = _decisions[index];
    return InkWell(
      onTap: () => setState(
        () =>
            selected ? _selectedItems.remove(index) : _selectedItems.add(index),
      ),
      onDoubleTap: () => setState(() {
        _current = index;
        _gridMode = false;
        _selectedItems.clear();
      }),
      child: Card(
        color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: preview == null
                  ? const Center(child: Icon(Icons.perm_media_outlined))
                  : Image.file(
                      File(preview.path),
                      fit: BoxFit.cover,
                      cacheWidth: 360,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: CircleAvatar(
                radius: 13,
                child: Icon(
                  selected ? Icons.check : Icons.circle_outlined,
                  size: 18,
                ),
              ),
            ),
            if (decision != null)
              Positioned(
                left: 6,
                bottom: 6,
                child: Chip(label: Text(_decisionLabel(decision))),
              ),
          ],
        ),
      ),
    );
  }

  String _decisionLabel(ReviewDecision decision) => switch (decision) {
    ReviewDecision.keepBoth => 'Both',
    ReviewDecision.keepJpeg => 'JPEG',
    ReviewDecision.keepCr3 => 'CR3',
    ReviewDecision.deleteBoth => 'Delete',
  };

  Widget _action(String key, String label, ReviewDecision decision) =>
      FilledButton.tonal(
        onPressed: () => _decide(decision),
        child: Text('$key  $label'),
      );

  Future<void> _showSettings() async {
    final controller = TextEditingController(text: _template);
    final keys = {
      for (final entry in _shortcuts.entries)
        entry.key: TextEditingController(text: entry.value),
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Destination template',
                  helperText:
                      'Tokens: {year}, {month}, {day}, {originalName}, {sourceFolder}',
                ),
              ),
              for (final decision in ReviewDecision.values)
                TextField(
                  controller: keys[decision],
                  maxLength: 1,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: '${decision.name} shortcut',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final values = keys.values
                  .map((value) => value.text.trim().toUpperCase())
                  .toList();
              if (values.any((value) => value.length != 1) ||
                  values.toSet().length != values.length) {
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || controller.text.trim().isEmpty) return;
    setState(() {
      _template = controller.text.trim();
      _shortcuts = {
        for (final decision in ReviewDecision.values)
          decision: keys[decision]!.text.trim().toUpperCase(),
      };
    });
    await _saveSettings();
  }

  Future<void> _showLibrary() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LibraryPage(assets: _libraryAssets),
    ),
  );
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.assets});

  final List<ImportedAsset> assets;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Library')),
    body: assets.isEmpty
        ? const Center(child: Text('Imported media will appear here.'))
        : GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: assets.length,
            itemBuilder: (_, index) {
              final asset = assets[index];
              final previewable =
                  asset.kind == MediaKind.jpeg || asset.kind == MediaKind.image;
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Expanded(
                      child: previewable
                          ? Image.file(
                              File(asset.path),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.broken_image_outlined),
                            )
                          : const Center(
                              child: Icon(Icons.perm_media_outlined, size: 48),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        path.basename(asset.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
  );
}
