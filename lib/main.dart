import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'domain/media.dart';
import 'domain/selection.dart';
import 'domain/view_options.dart';
import 'services/cr3_preview.dart';
import 'services/media_service.dart';
import 'shortcuts.dart';
import 'widgets/media_preview.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 500;
  runApp(const KinesisApp());
}

final themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

class KinesisApp extends StatelessWidget {
  const KinesisApp({super.key});

  static const _seed = Color(0xff176b67);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: themeModeNotifier,
    builder: (context, mode, _) => MaterialApp(
      title: 'Kinesis',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const KinesisHome(),
    ),
  );
}

class KinesisHome extends StatefulWidget {
  const KinesisHome({super.key});

  @override
  State<KinesisHome> createState() => _KinesisHomeState();
}

class _KinesisHomeState extends State<KinesisHome> {
  static final _readmeUri = Uri.parse(
    'https://github.com/MaxSloof/kinesis#readme',
  );

  final _media = MediaService();
  final _trash = TrashService();
  final _decisions = <int, ReviewDecision>{};
  final _autoDecisions = <int>{};
  List<ReviewItem> _items = [];
  LocalStore? _store;
  Set<String> _existingHashes = {};
  List<ImportedAsset> _libraryAssets = [];
  String? _library;
  String _template = '{year}/{year}-{month}-{day}';
  bool _splitRawAndJpeg = false;
  bool _vimKeys = true;
  String _jpegTemplate = 'JPEG/{year}/{year}-{month}-{day}';
  String _cr3Template = 'CRAW/{year}/{year}-{month}-{day}';
  Map<ReviewDecision, String> _shortcuts = {
    ReviewDecision.keepBoth: 'A',
    ReviewDecision.keepJpeg: 'S',
    ReviewDecision.keepCr3: 'D',
    ReviewDecision.deleteBoth: 'F',
  };
  int _current = 0;
  final _zoomController = TransformationController();
  Size _viewSize = Size.zero;
  int? _zoomedItem;
  int? _gridCursor;
  int _gridColumns = 1;
  final _tileKeys = <int, GlobalKey>{};
  bool _scanning = false;
  bool _gridMode = false;
  MediaSortOrder _sortOrder = MediaSortOrder.reviewDefault;
  bool _groupByDate = true;
  String? _source;
  StreamSubscription<FileSystemEvent>? _sourceWatch;
  Timer? _sourceRefreshTimer;
  bool _refreshingSource = false;
  bool _sourceRefreshPending = false;
  bool _ingesting = false;
  final _selection = MediaSelection();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _sourceRefreshTimer?.cancel();
    _sourceWatch?.cancel();
    _zoomController.dispose();
    super.dispose();
  }

  List<int>? _displayOrderCache;
  List<ReviewItem>? _displayOrderItems;
  MediaSortOrder? _displayOrderSort;

  int get _duplicateCleanupCount =>
      _items.where(ImportPlanner.needsDuplicateCleanup).length;

  bool get _hasManualChoices =>
      _decisions.keys.any((index) => !_autoDecisions.contains(index));

  bool get _canRemoveDuplicates =>
      _duplicateCleanupCount > 0 && !_hasManualChoices;

  void _removeDuplicates() {
    if (!_canRemoveDuplicates) return;
    setState(() {
      for (var index = 0; index < _items.length; index++) {
        final item = _items[index];
        if (!ImportPlanner.needsDuplicateCleanup(item)) continue;
        _decisions[index] = ImportPlanner.duplicateCleanupDecision(item);
        _autoDecisions.remove(index);
      }
    });
  }

  List<int> get _displayOrder {
    if (_displayOrderCache == null ||
        !identical(_displayOrderItems, _items) ||
        _displayOrderSort != _sortOrder) {
      _displayOrderItems = _items;
      _displayOrderSort = _sortOrder;
      _displayOrderCache = MediaViewOrder.sortReviewItemIndices(
        _items,
        _sortOrder,
      );
    }
    return _displayOrderCache!;
  }

  void _changeSortOrder(MediaSortOrder order) {
    if (order == _sortOrder) return;
    final currentPaths = _items.isNotEmpty && _current < _items.length
        ? _items[_displayOrder[_current]].files.map((file) => file.path).toSet()
        : <String>{};
    setState(() {
      _sortOrder = order;
      _selection.resetAnchor();
      final ordered = _displayOrder;
      final matching = ordered.indexWhere(
        (index) =>
            _items[index].files.any((file) => currentPaths.contains(file.path)),
      );
      if (matching >= 0) _current = matching;
    });
  }

  void _toggleDateGrouping() => setState(() => _groupByDate = !_groupByDate);

  Future<void> _openHelp() async {
    if (await launchUrl(_readmeUri, mode: LaunchMode.externalApplication)) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the Kinesis README.')),
    );
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
      _splitRawAndJpeg = state['splitRawAndJpeg'] as bool? ?? false;
      _vimKeys = state['vimKeys'] as bool? ?? true;
      _jpegTemplate = state['jpegTemplate'] as String? ?? _jpegTemplate;
      _cr3Template = state['cr3Template'] as String? ?? _cr3Template;
      themeModeNotifier.value = ThemeMode.values.firstWhere(
        (mode) => mode.name == state['themeMode'],
        orElse: () => ThemeMode.system,
      );
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
    await _refreshLibraryIndex();
  }

  Future<void> _refreshLibraryIndex() async {
    final library = _library;
    if (library == null) return;
    try {
      final hashes = await Future.wait(
        _indexRoots(library).map(_media.loadLibraryHashes),
      );
      if (!mounted) return;
      setState(() {
        _existingHashes = hashes.expand((value) => value).toSet();
      });
      await _saveSettings();
    } on FileSystemException {
      // Library access can be unavailable when a removable volume is absent.
    }
  }

  Future<void> _saveSettings() =>
      _store?.write({
        'library': _library,
        'hashes': _existingHashes.toList(),
        'assets': _libraryAssets.map((asset) => asset.toJson()).toList(),
        'template': _template,
        'splitRawAndJpeg': _splitRawAndJpeg,
        'vimKeys': _vimKeys,
        'jpegTemplate': _jpegTemplate,
        'cr3Template': _cr3Template,
        'themeMode': themeModeNotifier.value.name,
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
    final changed = selected != _library;
    setState(() {
      _library = selected;
      if (changed) {
        _existingHashes = {};
        _libraryAssets = [];
      }
    });
    await _saveSettings();
    // Duplicate flags and their default decisions belong to the old library.
    if (changed && _source != null && !_scanning && !_ingesting) {
      await _refreshSourceListing();
    }
  }

  Future<void> _chooseSource() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a camera card or source folder',
    );
    if (selected == null) return;
    final previousSource = _source;
    _source = selected;
    _sourceRefreshTimer?.cancel();
    final previousWatch = _sourceWatch;
    _sourceWatch = null;
    await previousWatch?.cancel();
    setState(() => _scanning = true);
    final scanWatch = Stopwatch()..start();
    debugPrint('[scan] source=$selected started');
    try {
      final sourceWatch = Stopwatch()..start();
      final scanned = await _media.scan(selected);
      sourceWatch.stop();
      final sourceFileCount = scanned.fold<int>(
        0,
        (count, item) => count + item.files.length,
      );
      debugPrint(
        '[scan] source listing: ${sourceWatch.elapsedMilliseconds}ms, '
        '$sourceFileCount files in ${scanned.length} review items',
      );
      final libraryWatch = Stopwatch()..start();
      final libraryHashesBySize = <int, Set<String>>{};
      if (_library != null) {
        final indexes = await Future.wait(
          _indexRoots(_library!).map(_media.libraryHashesBySize),
        );
        for (final index in indexes) {
          for (final entry in index.entries) {
            libraryHashesBySize
                .putIfAbsent(entry.key, () => {})
                .addAll(entry.value);
          }
        }
      }
      libraryWatch.stop();
      final libraryFileCount = libraryHashesBySize.values.fold<int>(
        0,
        (count, hashes) => count + hashes.length,
      );
      debugPrint(
        '[scan] destination index: ${libraryWatch.elapsedMilliseconds}ms, '
        '$libraryFileCount files in ${libraryHashesBySize.length} size groups',
      );
      final duplicateWatch = Stopwatch()..start();
      final marked = await _media.markExisting(scanned, libraryHashesBySize);
      duplicateWatch.stop();
      final duplicateCount = marked.fold<int>(
        0,
        (count, item) =>
            count + item.files.where((file) => file.alreadyExists).length,
      );
      debugPrint(
        '[scan] duplicate check: ${duplicateWatch.elapsedMilliseconds}ms, '
        '$duplicateCount exact duplicates',
      );
      final jpegWatch = Stopwatch()..start();
      final withLibraryJpegs = _attachLibraryJpegs(
        marked,
        await _libraryJpegs(),
      );
      debugPrint(
        '[scan] destination JPEG matches: '
        '${withLibraryJpegs.where((item) => item.existingJpeg != null).length} '
        'in ${jpegWatch.elapsedMilliseconds}ms',
      );
      if (mounted) {
        setState(() {
          _items = withLibraryJpegs;
          _decisions
            ..clear()
            ..addAll(ImportPlanner.defaultDecisions(withLibraryJpegs));
          _autoDecisions
            ..clear()
            ..addAll(_decisions.keys);
          _selection.clear();
          _current = 0;
          _gridMode = false;
          _existingHashes.addAll(
            libraryHashesBySize.values.expand((hashes) => hashes),
          );
        });
        await _watchSource(selected);
      }
    } on Object catch (error, stackTrace) {
      debugPrint('[scan] failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        if (previousSource == null) {
          _source = null;
        } else {
          await _watchSource(previousSource);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not scan source: $error')),
        );
      }
    } finally {
      scanWatch.stop();
      debugPrint('[scan] completed in ${scanWatch.elapsedMilliseconds}ms');
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _watchSource(String source) async {
    _sourceRefreshTimer?.cancel();
    final previousWatch = _sourceWatch;
    _sourceWatch = null;
    await previousWatch?.cancel();
    _source = source;
    try {
      _sourceWatch = Directory(source)
          .watch(recursive: true)
          .listen(
            (_) => _scheduleSourceRefresh(),
            onError: (Object error) {
              debugPrint('[scan] source watch failed: $error');
            },
          );
    } on FileSystemException catch (error) {
      debugPrint('[scan] could not watch source folder: $error');
    }
  }

  void _scheduleSourceRefresh() {
    _sourceRefreshTimer?.cancel();
    _sourceRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (_ingesting) {
        _sourceRefreshPending = true;
        return;
      }
      unawaited(_refreshSourceListing());
    });
  }

  Future<void> _refreshSourceListing() async {
    final source = _source;
    if (!mounted || source == null) return;
    if (_ingesting || _refreshingSource) {
      _sourceRefreshPending = true;
      return;
    }
    _refreshingSource = true;
    try {
      final scanned = await _media.scan(source);
      final hashesBySize = <int, Set<String>>{};
      final library = _library;
      if (library != null) {
        final indexes = await Future.wait(
          _indexRoots(library).map(_media.libraryHashesBySize),
        );
        for (final index in indexes) {
          for (final entry in index.entries) {
            hashesBySize.putIfAbsent(entry.key, () => {}).addAll(entry.value);
          }
        }
      }
      final refreshed = _attachLibraryJpegs(
        await _media.markExisting(scanned, hashesBySize),
        await _libraryJpegs(),
      );
      if (!mounted || _source != source) return;

      final decisionsByPath = <String, ReviewDecision>{};
      for (final entry in _decisions.entries) {
        if (entry.key < _items.length) {
          for (final file in _items[entry.key].files) {
            decisionsByPath[file.path] = entry.value;
          }
        }
      }
      final autoPaths = <String>{};
      for (final index in _autoDecisions) {
        if (index < _items.length) {
          autoPaths.addAll(_items[index].files.map((file) => file.path));
        }
      }
      final selectedPaths = <String>{
        for (final index in _selection.indices)
          if (index < _items.length)
            for (final file in _items[index].files) file.path,
      };
      final visibleOrder = _displayOrder;
      final currentPaths = _current < visibleOrder.length
          ? _items[visibleOrder[_current]].files
                .map((file) => file.path)
                .toSet()
          : <String>{};
      setState(() {
        _items = refreshed;
        _existingHashes
          ..clear()
          ..addAll(hashesBySize.values.expand((hashes) => hashes));
        final preserved = <int, ReviewDecision>{};
        final preservedAuto = <int>{};
        for (var index = 0; index < refreshed.length; index++) {
          final decision = refreshed[index].files
              .map((file) => decisionsByPath[file.path])
              .whereType<ReviewDecision>()
              .firstOrNull;
          if (decision == null) continue;
          final wasAuto = refreshed[index].files.every(
            (file) => autoPaths.contains(file.path),
          );
          // Do not keep a defaulted Delete both after the library match it was
          // based on has disappeared.
          if (wasAuto &&
              !ImportPlanner.needsDuplicateCleanup(refreshed[index])) {
            continue;
          }
          preserved[index] = decision;
          if (wasAuto) preservedAuto.add(index);
        }
        for (final entry in ImportPlanner.defaultDecisions(refreshed).entries) {
          if (preserved.containsKey(entry.key)) continue;
          preserved[entry.key] = entry.value;
          preservedAuto.add(entry.key);
        }
        _decisions
          ..clear()
          ..addAll(preserved);
        _autoDecisions
          ..clear()
          ..addAll(preservedAuto);
        _selection.replaceWith([
          for (var index = 0; index < refreshed.length; index++)
            if (refreshed[index].files.any(
              (file) => selectedPaths.contains(file.path),
            ))
              index,
        ]);
        final refreshedOrder = MediaViewOrder.sortReviewItemIndices(
          refreshed,
          _sortOrder,
        );
        final matchingCurrent = refreshedOrder.indexWhere(
          (index) => refreshed[index].files.any(
            (file) => currentPaths.contains(file.path),
          ),
        );
        _current = refreshed.isEmpty
            ? 0
            : matchingCurrent >= 0
            ? matchingCurrent
            : _current.clamp(0, refreshed.length - 1).toInt();
      });
    } on FileSystemException catch (error) {
      debugPrint('[scan] source refresh failed: $error');
    } finally {
      _refreshingSource = false;
      if (_sourceRefreshPending && mounted && !_ingesting) {
        _sourceRefreshPending = false;
        _scheduleSourceRefresh();
      }
    }
  }

  void _decide(ReviewDecision decision) {
    if (_items.isEmpty) return;
    setState(() {
      if (_gridMode && _selection.isNotEmpty) {
        for (final index in _selection.indices) {
          _decisions[index] = decision;
          _autoDecisions.remove(index);
        }
        return;
      }
      final visibleOrder = _displayOrder;
      if (_current >= visibleOrder.length) return;
      final index = visibleOrder[_current];
      _decisions[index] = decision;
      _autoDecisions.remove(index);
      if (_current < visibleOrder.length - 1) _current++;
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
        if (entry.key >= _items.length) return total;
        final next = planner.plan(_items[entry.key], entry.value);
        return ImportPlan(
          toImport: [...total.toImport, ...next.toImport],
          toDelete: [...total.toDelete, ...next.toDelete],
          skipped: [...total.skipped, ...next.skipped],
        );
      },
    );
    final unchangedFiles = <MediaFile>[
      for (var index = 0; index < _items.length; index++)
        if (!_decisions.containsKey(index)) ..._items[index].files,
    ];
    final alreadyInLibraryFiles = <MediaFile>[
      for (final index in _decisions.keys)
        if (index < _items.length)
          ..._items[index].files.where((file) => file.alreadyExists),
    ];
    final duplicateFiles = alreadyInLibraryFiles.length;
    final libraryJpegReferences = _decisions.keys
        .where((index) => index < _items.length)
        .where((index) => _items[index].existingJpeg != null)
        .length;
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm ingest plan'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Only files in “Copy / verify candidates” can be written to '
                  'the library. Source files listed for Trash are a separate '
                  'action and move after copies are verified.',
                ),
                const SizedBox(height: 16),
                _ingestPlanTable(plan, alreadyInLibraryFiles, unchangedFiles),
                if (libraryJpegReferences > 0) ...[
                  const SizedBox(height: 16),
                  Text(
                    '$libraryJpegReferences matching '
                    '${libraryJpegReferences == 1 ? 'JPEG' : 'JPEGs'} in the '
                    'library '
                    '${libraryJpegReferences == 1 ? 'is' : 'are'} '
                    'preview-only; they will not be copied or moved.',
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'If multiple selected source files have identical content, '
                  'only the first is copied; later copies are skipped. Files '
                  'with no decision remain unchanged.',
                ),
              ],
            ),
          ),
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
    if (approved != true || !mounted) return;
    _ingesting = true;
    final knownHashes = <String>{..._existingHashes};
    final importedAssets = <ImportedAsset>[];
    var skipped = 0;
    final totalSteps = plan.toImport.length + plan.toDelete.length;
    final progress = ValueNotifier(
      _IngestProgress(
        phase: 'Copying and verifying',
        done: 0,
        total: totalSteps,
      ),
    );
    var stepsDone = 0;
    void step(String phase, String? file) {
      stepsDone++;
      progress.value = _IngestProgress(
        phase: phase,
        done: stepsDone,
        total: totalSteps,
        currentFile: file,
      );
    }

    _progressOpen = true;
    final dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: _IngestProgressDialog(progress: progress),
      ),
    );
    try {
      for (final file in plan.toImport) {
        progress.value = _IngestProgress(
          phase: 'Copying and verifying',
          done: stepsDone,
          total: totalSteps,
          currentFile: path.basename(file.path),
        );
        final sourceHash = await _media.hashFile(file.path);
        if (!knownHashes.add(sourceHash)) {
          skipped++;
          step('Copying and verifying', path.basename(file.path));
          continue;
        }
        importedAssets.add(
          await _media.copyAndVerify(
            file.withHash(sourceHash),
            _library!,
            _templateFor(file),
          ),
        );
        step('Copying and verifying', path.basename(file.path));
      }
      progress.value = _IngestProgress(
        phase: 'Updating library index',
        done: stepsDone,
        total: totalSteps,
      );
      _existingHashes.addAll(importedAssets.map((asset) => asset.hash));
      _libraryAssets.addAll(importedAssets);
      await Future.wait(
        _indexRoots(_library!).map(
          (root) =>
              _media.writeImportedAssetsToLibraryIndex(root, importedAssets),
        ),
      );
      await _saveSettings();
      for (final file in plan.toDelete) {
        progress.value = _IngestProgress(
          phase: 'Moving sources to Trash',
          done: stepsDone,
          total: totalSteps,
          currentFile: path.basename(file.path),
        );
        if (await File(file.path).exists()) {
          await _trash.moveToTrash(file.path);
        }
        step('Moving sources to Trash', path.basename(file.path));
      }
      _closeProgress(dialogClosed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Ingest completed.'
              '${skipped + duplicateFiles > 0 ? ' ${skipped + duplicateFiles} duplicate source files skipped.' : ''}'
              '${libraryJpegReferences > 0 ? ' $libraryJpegReferences matching library JPEGs left unchanged.' : ''}',
            ),
          ),
        );
      }
    } on FileSystemException catch (error) {
      _closeProgress(dialogClosed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ingest stopped: ${error.message}')),
        );
      }
    } on PlatformException catch (error) {
      _closeProgress(dialogClosed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not move a source file to Trash: ${error.message}',
            ),
          ),
        );
      }
    } finally {
      _closeProgress(dialogClosed);
      await dialogClosed;
      progress.dispose();
      _ingesting = false;
      _sourceRefreshPending = false;
      _sourceRefreshTimer?.cancel();
      await _refreshSourceListing();
    }
  }

  Widget _ingestPlanTable(
    ImportPlan plan,
    List<MediaFile> alreadyInLibraryFiles,
    List<MediaFile> unchangedFiles,
  ) {
    final colors = Theme.of(context).colorScheme;

    TableRow row(String action, List<MediaFile> files, {bool header = false}) {
      final jpegCount = files
          .where((file) => file.kind == MediaKind.jpeg)
          .length;
      final cr3Count = files.where((file) => file.kind == MediaKind.cr3).length;
      final otherCount = files.length - jpegCount - cr3Count;
      final values = header
          ? [action, 'JPEG', 'CR3', 'Other', 'Total']
          : [
              action,
              '$jpegCount',
              '$cr3Count',
              '$otherCount',
              '${files.length}',
            ];
      return TableRow(
        decoration: header
            ? BoxDecoration(color: colors.surfaceContainerHighest)
            : null,
        children: [
          for (var index = 0; index < values.length; index++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: index == 0
                  ? Text(
                      values[index],
                      style: header
                          ? Theme.of(context).textTheme.titleSmall
                          : null,
                    )
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        values[index],
                        style: header
                            ? Theme.of(context).textTheme.titleSmall
                            : null,
                      ),
                    ),
            ),
        ],
      );
    }

    return Table(
      border: TableBorder.all(color: colors.outlineVariant),
      columnWidths: const {
        0: FlexColumnWidth(3),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(1),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        row('Action', const [], header: true),
        row('Copy / verify candidates', plan.toImport),
        row('Already in library (not copied)', alreadyInLibraryFiles),
        row('Move selected source files to Trash', plan.toDelete),
        row('Leave unchanged', unchangedFiles),
      ],
    );
  }

  bool _progressOpen = false;

  void _closeProgress(Future<void> dialogClosed) {
    if (!_progressOpen) return;
    _progressOpen = false;
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  String _templateFor(MediaFile file) {
    if (!_splitRawAndJpeg) return _template;
    return switch (file.kind) {
      MediaKind.jpeg => _jpegTemplate,
      MediaKind.cr3 => _cr3Template,
      _ => _template,
    };
  }

  Iterable<String> _indexRoots(String library) => {
    if (_splitRawAndJpeg) ...[
      _indexRoot(library, _jpegTemplate),
      _indexRoot(library, _cr3Template),
    ] else
      _indexRoot(library, _template),
  };

  String _indexRoot(String library, String template) {
    final parts = path.split(template);
    final fixedParts = <String>[];
    for (final part in parts) {
      if (part.contains('{')) break;
      fixedParts.add(part);
    }
    return path.joinAll([library, ...fixedParts]);
  }

  /// JPEGs that already live in the destination, keyed by lowercase shot name.
  /// A RAW on the source card can be paired with one of these for preview and
  /// review context without importing the destination file again.
  Future<Map<String, MediaFile>> _libraryJpegs() async {
    final library = _library;
    if (library == null) return const {};
    final jpegRoot = _splitRawAndJpeg
        ? _indexRoot(library, _jpegTemplate)
        : _indexRoot(library, _template);
    return _media.libraryJpegs(jpegRoot);
  }

  List<ReviewItem> _attachLibraryJpegs(
    List<ReviewItem> items,
    Map<String, MediaFile> jpegs,
  ) {
    if (jpegs.isEmpty) return items;
    var changed = false;
    final result = <ReviewItem>[];
    for (final item in items) {
      if (item.jpeg == null && item.cr3 != null) {
        final match = jpegs[item.cr3!.stem];
        if (match != null) {
          result.add(item.withExistingJpeg(match));
          changed = true;
          continue;
        }
      }
      result.add(item);
    }
    return changed ? result : items;
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (final decision in ReviewDecision.values)
        SingleActivator(logicalKeyForShortcut(_shortcuts[decision]!)): () =>
            _decide(decision),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _navigate(-1, 0),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _navigate(1, 0),
      if (_vimKeys)
        const SingleActivator(LogicalKeyboardKey.keyH): () => _navigate(-1, 0),
      if (_vimKeys)
        const SingleActivator(LogicalKeyboardKey.keyK): () => _navigate(0, -1),
      if (_vimKeys)
        const SingleActivator(LogicalKeyboardKey.keyL): () => _navigate(1, 0),
      if (_vimKeys)
        const SingleActivator(LogicalKeyboardKey.keyJ): () => _navigate(0, 1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _navigate(0, -1),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          _navigate(0, 1),
      const SingleActivator(LogicalKeyboardKey.space): _toggleCursorTile,
      const SingleActivator(LogicalKeyboardKey.equal, meta: true): () =>
          _zoomBy(1.25),
      const SingleActivator(LogicalKeyboardKey.add, meta: true): () =>
          _zoomBy(1.25),
      const SingleActivator(LogicalKeyboardKey.numpadAdd, meta: true): () =>
          _zoomBy(1.25),
      const SingleActivator(LogicalKeyboardKey.minus, meta: true): () =>
          _zoomBy(0.8),
      const SingleActivator(
        LogicalKeyboardKey.numpadSubtract,
        meta: true,
      ): () =>
          _zoomBy(0.8),
      const SingleActivator(LogicalKeyboardKey.digit0, meta: true): () =>
          _zoomController.value = Matrix4.identity(),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SvgPicture.asset(
                  'assets/logo.svg',
                  width: 28,
                  height: 28,
                ),
              ),
              const SizedBox(width: 10),
              const Flexible(
                child: Text(
                  'Kinesis',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: MediaQuery.sizeOf(context).width < 700
              ? _compactAppBarActions()
              : [
                  IconButton(
                    onPressed: _openHelp,
                    icon: const Icon(Icons.help_outline),
                    tooltip: 'Help',
                  ),
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
                  if (_items.isNotEmpty) ...[
                    IconButton(
                      onPressed: () => setState(() {
                        _gridMode = !_gridMode;
                        _selection.clear();
                      }),
                      icon: Icon(
                        _gridMode
                            ? Icons.fullscreen_outlined
                            : Icons.grid_view_outlined,
                      ),
                      tooltip: _gridMode
                          ? 'Single image review'
                          : 'Grid review',
                    ),
                    PopupMenuButton<MediaSortOrder>(
                      tooltip: 'Sort ingest review',
                      icon: const Icon(Icons.sort),
                      onSelected: _changeSortOrder,
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: MediaSortOrder.nameAscending,
                          child: Text('Name (A–Z)'),
                        ),
                        PopupMenuItem(
                          value: MediaSortOrder.nameDescending,
                          child: Text('Name (Z–A)'),
                        ),
                        PopupMenuItem(
                          value: MediaSortOrder.captureNewest,
                          child: Text('Capture date (newest)'),
                        ),
                        PopupMenuItem(
                          value: MediaSortOrder.captureOldest,
                          child: Text('Capture date (oldest)'),
                        ),
                        PopupMenuItem(
                          value: MediaSortOrder.sizeLargest,
                          child: Text('File size (largest)'),
                        ),
                        PopupMenuItem(
                          value: MediaSortOrder.sizeSmallest,
                          child: Text('File size (smallest)'),
                        ),
                      ],
                    ),
                    IconButton(
                      onPressed: _toggleDateGrouping,
                      icon: Icon(
                        _groupByDate
                            ? Icons.calendar_month
                            : Icons.calendar_month_outlined,
                      ),
                      tooltip: _groupByDate ? 'Ungroup dates' : 'Group by date',
                    ),
                  ],
                  TextButton.icon(
                    onPressed: _chooseLibrary,
                    icon: const Icon(Icons.folder_outlined),
                    label: Text(
                      _library == null ? 'Set library' : 'Library set',
                    ),
                  ),
                ],
        ),
        body: _items.isEmpty
            ? _welcome()
            : (_gridMode ? _reviewGrid() : _review()),
        floatingActionButton: _items.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: _canRemoveDuplicates
                    ? _removeDuplicates
                    : _decisions.isEmpty
                    ? null
                    : _confirm,
                tooltip: _canRemoveDuplicates
                    ? 'Skip JPEGs already in the library and keep missing CR3s'
                    : 'Review ingest plan',
                icon: Icon(
                  _canRemoveDuplicates
                      ? Icons.delete_sweep_outlined
                      : Icons.fact_check_outlined,
                ),
                label: Text(
                  _canRemoveDuplicates
                      ? 'Remove duplicates ($_duplicateCleanupCount)'
                      : 'Review plan (${_decisions.length})',
                ),
              ),
      ),
    ),
  );

  List<Widget> _compactAppBarActions() => [
    IconButton(
      onPressed: _openHelp,
      icon: const Icon(Icons.help_outline),
      tooltip: 'Help',
    ),
    PopupMenuButton<String>(
      tooltip: 'More options',
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case 'settings':
            _showSettings();
          case 'library':
            _showLibrary();
          case 'chooseLibrary':
            _chooseLibrary();
          case 'toggleGrid':
            setState(() {
              _gridMode = !_gridMode;
              _selection.clear();
            });
          case 'toggleDateGrouping':
            _toggleDateGrouping();
          default:
            if (action.startsWith('sort:')) {
              _changeSortOrder(
                MediaSortOrder.values.byName(action.substring('sort:'.length)),
              );
            }
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'chooseLibrary',
          child: Text(_library == null ? 'Set library' : 'Change library'),
        ),
        const PopupMenuItem(value: 'library', child: Text('Open library')),
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
        if (_items.isNotEmpty) ...[
          PopupMenuItem(
            value: 'toggleGrid',
            child: Text(_gridMode ? 'Single image review' : 'Grid review'),
          ),
          PopupMenuItem(
            value: 'toggleDateGrouping',
            child: Text(_groupByDate ? 'Ungroup dates' : 'Group by date'),
          ),
          const PopupMenuDivider(),
          for (final order in MediaSortOrder.values)
            PopupMenuItem(
              value: 'sort:${order.name}',
              child: Text(_sortOrderLabel(order)),
            ),
        ],
      ],
    ),
  ];

  String _sortOrderLabel(MediaSortOrder order) => switch (order) {
    MediaSortOrder.nameAscending => 'Name (A–Z)',
    MediaSortOrder.nameDescending => 'Name (Z–A)',
    MediaSortOrder.captureNewest => 'Capture date (newest)',
    MediaSortOrder.captureOldest => 'Capture date (oldest)',
    MediaSortOrder.sizeLargest => 'File size (largest)',
    MediaSortOrder.sizeSmallest => 'File size (smallest)',
  };

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
    final visibleOrder = _displayOrder;
    final itemIndex = visibleOrder[_current];
    final item = _items[itemIndex];
    final decision = _decisions[itemIndex];
    final preview = _previewFor(item);
    if (_zoomedItem != itemIndex) {
      _zoomedItem = itemIndex;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _zoomController.value = Matrix4.identity(),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${_current + 1} of ${_items.length}'),
          const SizedBox(height: 16),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _viewSize = constraints.biggest;
                      return InteractiveViewer(
                        transformationController: _zoomController,
                        maxScale: 8,
                        child: Center(
                          child: MediaPreview(
                            preview: preview,
                            cr3Path: item.cr3?.path,
                            fit: BoxFit.contain,
                            cacheWidth: 1600,
                            loading: const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            placeholder: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.perm_media_outlined, size: 96),
                                const SizedBox(height: 16),
                                Text(item.displayName),
                                const Text('Preview unavailable'),
                              ],
                            ),
                            errorPlaceholder: Text(item.displayName),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: Column(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => _zoomBy(1.25),
                        icon: const Icon(Icons.add),
                        tooltip: 'Zoom in (⌘+)',
                      ),
                      const SizedBox(height: 4),
                      IconButton.filledTonal(
                        onPressed: () => _zoomBy(0.8),
                        icon: const Icon(Icons.remove),
                        tooltip: 'Zoom out (⌘−)',
                      ),
                    ],
                  ),
                ),
                if (item.isDuplicate)
                  Positioned.fill(child: _duplicateOverlay()),
                Positioned(left: 12, top: 12, child: _formatBadges(item)),
                if (decision != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: Center(child: _selectedActionBadge(decision)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _previewStrip(),
          const SizedBox(height: 12),
          Text(item.displayName, textAlign: TextAlign.center),
          if (item.existingJpeg != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.library_add_check_outlined,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'JPEG already in library',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '${MediaViewOrder.captureDateLabel(item.captureDate)}  ·  '
            '${MediaViewOrder.sizeLabel(item.sizeBytes)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
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

  void _zoomBy(double factor) {
    if (_gridMode || _items.isEmpty) return;
    final current = _zoomController.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, 8.0);
    final ratio = target / current;
    final center = Offset(_viewSize.width / 2, _viewSize.height / 2);
    final next = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(ratio, ratio, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(_zoomController.value);
    if (target <= 1.0) {
      _zoomController.value = Matrix4.identity();
    } else {
      _zoomController.value = next;
    }
  }

  List<MediaDateGroup<int>> _gridGroups() => _groupByDate
      ? MediaViewOrder.groupByCaptureDate<int>(
          _displayOrder,
          (index) => _items[index].captureDate,
          newestFirst: _sortOrder != MediaSortOrder.captureOldest,
        )
      : [MediaDateGroup(label: '', items: _displayOrder)];

  void _navigate(int dx, int dy) {
    if (_items.isEmpty) return;
    if (!_gridMode) {
      final step = dx + dy;
      if (step != 0) _moveCurrent(step);
      return;
    }
    final groups = _gridGroups().where((g) => g.items.isNotEmpty).toList();
    if (groups.isEmpty) return;
    var gi = 0;
    var ii = 0;
    final cursor = _gridCursor;
    var found = false;
    if (cursor != null) {
      for (var g = 0; g < groups.length && !found; g++) {
        final i = groups[g].items.indexOf(cursor);
        if (i >= 0) {
          gi = g;
          ii = i;
          found = true;
        }
      }
    }
    if (found) {
      final cols = _gridColumns;
      if (dx != 0) {
        ii += dx;
        if (ii < 0) {
          if (gi == 0) return;
          gi--;
          ii = groups[gi].items.length - 1;
        } else if (ii >= groups[gi].items.length) {
          if (gi == groups.length - 1) return;
          gi++;
          ii = 0;
        }
      } else if (dy != 0) {
        final col = ii % cols;
        final target = ii + dy * cols;
        if (target < 0) {
          if (gi == 0) return;
          gi--;
          final len = groups[gi].items.length;
          final lastRowStart = ((len - 1) ~/ cols) * cols;
          ii = (lastRowStart + col).clamp(0, len - 1);
        } else if (target >= groups[gi].items.length) {
          final len = groups[gi].items.length;
          final inLastRow = ii >= ((len - 1) ~/ cols) * cols;
          if (inLastRow) {
            if (gi == groups.length - 1) return;
            gi++;
            ii = col.clamp(0, groups[gi].items.length - 1);
          } else {
            ii = len - 1;
          }
        } else {
          ii = target;
        }
      }
    }
    final next = groups[gi].items[ii];
    setState(() => _gridCursor = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tileKeys[next]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.5);
      }
    });
  }

  void _toggleCursorTile() {
    final cursor = _gridCursor;
    if (!_gridMode || cursor == null) return;
    _toggleGridSelection(cursor);
  }

  void _moveCurrent(int offset) {
    if (_gridMode) return;
    final next = _current + offset;
    if (next < 0 || next >= _items.length) return;
    setState(() => _current = next);
    _prefetchAround(next);
  }

  void _prefetchAround(int index) {
    if (!mounted) return;
    final order = _displayOrder;
    for (final offset in const [1, -1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= order.length) continue;
      final item = _items[order[i]];
      final preview = _previewFor(item);
      if (preview != null) {
        unawaited(
          precacheImage(
            ResizeImage(FileImage(File(preview.path)), width: 1600),
            context,
            onError: (_, _) {},
          ),
        );
      } else if (item.cr3 != null) {
        unawaited(
          Cr3PreviewCache.instance.previewFor(item.cr3!.path).then((file) {
            if (file == null || !mounted) return;
            unawaited(
              precacheImage(
                ResizeImage(FileImage(file), width: 1600),
                context,
                onError: (_, _) {},
              ),
            );
          }),
        );
      }
    }
  }

  MediaFile? _previewFor(ReviewItem item) =>
      item.jpeg ??
      item.existingJpeg ??
      (item.single?.kind == MediaKind.image ? item.single : null);

  Widget _previewStrip() {
    final visibleOrder = _displayOrder;
    const window = 7;
    final count = visibleOrder.length;
    final first = (_current - 3)
        .clamp(0, (count - window).clamp(0, count))
        .toInt();
    final last = (first + window - 1).clamp(0, count - 1).toInt();
    final shown = last - first + 1;
    return SizedBox(
      height: 76,
      child: Center(
        child: SizedBox(
          width: shown * 108.0 + (shown - 1) * 8.0,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: shown,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, stripIndex) {
              final index = first + stripIndex;
              final itemIndex = visibleOrder[index];
              final item = _items[itemIndex];
              final decision = _decisions[itemIndex];
              final preview = _previewFor(item);
              return Semantics(
                button: true,
                label:
                    'Show image ${index + 1}'
                    '${decision == null ? '' : ', selected action: ${_selectedActionLabel(decision)}'}',
                child: InkWell(
                  onTap: () {
                    setState(() => _current = index);
                    _prefetchAround(index);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Ink(
                    width: 108,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: index == _current
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                        width: index == _current ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MediaPreview(
                            preview: preview,
                            cr3Path: item.cr3?.path,
                            fit: BoxFit.cover,
                            cacheWidth: 216,
                            placeholder: const Icon(Icons.perm_media_outlined),
                            loading: const SizedBox.shrink(),
                            errorPlaceholder: const Icon(
                              Icons.broken_image_outlined,
                            ),
                          ),
                          if (decision != null)
                            Positioned(
                              left: 3,
                              right: 3,
                              bottom: 3,
                              child: _thumbnailActionBadge(decision),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _thumbnailActionBadge(ReviewDecision decision) {
    final colors = Theme.of(context).colorScheme;
    final isDelete = decision == ReviewDecision.deleteBoth;
    final background = isDelete
        ? colors.errorContainer
        : colors.primaryContainer;
    final foreground = isDelete
        ? colors.onErrorContainer
        : colors.onPrimaryContainer;

    return Tooltip(
      message: 'Selected action: ${_selectedActionLabel(decision)}',
      child: Material(
        color: background,
        elevation: 3,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            _selectedActionLabel(decision),
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _duplicateOverlay() => ColoredBox(
    color: Colors.white60,
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Colors.black54,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Duplicate',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'sources deleted by default',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _reviewGrid() {
    final visibleOrder = _displayOrder;
    final groups = _groupByDate
        ? MediaViewOrder.groupByCaptureDate<int>(
            visibleOrder,
            (index) => _items[index].captureDate,
            newestFirst: _sortOrder != MediaSortOrder.captureOldest,
          )
        : [MediaDateGroup(label: '', items: visibleOrder)];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              Text(
                '${_selection.length} selected',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 6),
              Tooltip(
                message:
                    'Shift-click a tile to select every image between it and '
                    'the last clicked tile.',
                child: const Icon(Icons.info_outline, size: 16),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    setState(() => _selection.selectAll(visibleOrder)),
                child: const Text('Select all'),
              ),
              TextButton(
                onPressed: () => setState(_selection.clear),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _gridColumns = ((constraints.maxWidth - 32 + 12) / (180 + 12))
                  .ceil()
                  .clamp(1, 1000);
              return CustomScrollView(
                slivers: [
                  for (final group in groups) ...[
                    if (_groupByDate)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group.label,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              TextButton(
                                onPressed: () =>
                                    _toggleGroupSelection(group.items),
                                child: Text(
                                  _selection.containsAll(group.items)
                                      ? 'Clear day'
                                      : 'Select day',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                            ),
                        delegate: SliverChildBuilderDelegate(
                          (_, index) => _gridTile(group.items[index]),
                          childCount: group.items.length,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        if (_selection.isNotEmpty)
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
  }

  void _toggleGroupSelection(Iterable<int> indices) {
    setState(() => _selection.toggleAll(indices));
  }

  void _toggleGridSelection(int logicalIndex) {
    setState(() {
      _selection.tap(
        logicalIndex,
        displayOrder: _displayOrder,
        extend: HardwareKeyboard.instance.isShiftPressed,
      );
    });
  }

  Widget _gridTile(int logicalIndex) {
    final item = _items[logicalIndex];
    final preview = _previewFor(item);
    final selected = _selection.contains(logicalIndex);
    final decision = _decisions[logicalIndex];
    final isDuplicate = item.isDuplicate;
    final focused = _gridCursor == logicalIndex;
    return InkWell(
      key: _tileKeys.putIfAbsent(logicalIndex, GlobalKey.new),
      onTap: () {
        setState(() => _gridCursor = logicalIndex);
        _toggleGridSelection(logicalIndex);
      },
      onDoubleTap: () => setState(() {
        _current = _displayOrder.indexOf(logicalIndex);
        _gridMode = false;
        _selection.clear();
      }),
      child: Card(
        color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        shape: focused
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
              )
            : null,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: MediaPreview(
                preview: preview,
                cr3Path: item.cr3?.path,
                fit: BoxFit.cover,
                cacheWidth: 360,
                placeholder: const Center(
                  child: Icon(Icons.perm_media_outlined),
                ),
                loading: const SizedBox.shrink(),
                errorPlaceholder: const Center(
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ColoredBox(
                color: Colors.black54,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      Text(
                        MediaViewOrder.sizeLabel(item.sizeBytes),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isDuplicate) Positioned.fill(child: _duplicateOverlay()),
            Positioned(
              left: 6,
              top: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _formatBadges(item),
                  if (decision != null) ...[
                    const SizedBox(height: 4),
                    Chip(label: Text(_decisionLabel(decision))),
                  ],
                ],
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

  String _selectedActionLabel(ReviewDecision decision) => switch (decision) {
    ReviewDecision.keepBoth => 'Keep both',
    ReviewDecision.keepJpeg => 'Keep JPEG',
    ReviewDecision.keepCr3 => 'Keep CR3',
    ReviewDecision.deleteBoth => 'Delete both',
  };

  Widget _selectedActionBadge(ReviewDecision decision) {
    final colors = Theme.of(context).colorScheme;
    final isDelete = decision == ReviewDecision.deleteBoth;
    final background = isDelete
        ? colors.errorContainer
        : colors.primaryContainer;
    final foreground = isDelete
        ? colors.onErrorContainer
        : colors.onPrimaryContainer;
    final icon = switch (decision) {
      ReviewDecision.keepBoth => Icons.done_all,
      ReviewDecision.keepJpeg => Icons.photo_outlined,
      ReviewDecision.keepCr3 => Icons.raw_on_outlined,
      ReviewDecision.deleteBoth => Icons.delete_outline,
    };

    return Semantics(
      container: true,
      label: 'Selected action: ${_selectedActionLabel(decision)}',
      child: Material(
        color: background,
        elevation: 6,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground, size: 22),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SELECTED ACTION',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    _selectedActionLabel(decision),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(String key, String label, ReviewDecision decision) =>
      FilledButton.tonal(
        onPressed: () => _decide(decision),
        child: Text('$key  $label'),
      );

  Future<void> _showSettings() async {
    final controller = TextEditingController(text: _template);
    var splitRawAndJpeg = _splitRawAndJpeg;
    var vimKeys = _vimKeys;
    final jpegController = TextEditingController(text: _jpegTemplate);
    final cr3Controller = TextEditingController(text: _cr3Template);
    var themeMode = themeModeNotifier.value;
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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatefulBuilder(
                  builder: (context, setDialogState) =>
                      DropdownButtonFormField<ThemeMode>(
                        initialValue: themeMode,
                        decoration: const InputDecoration(labelText: 'Theme'),
                        items: const [
                          DropdownMenuItem(
                            value: ThemeMode.system,
                            child: Text('System'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.light,
                            child: Text('Light'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.dark,
                            child: Text('Dark'),
                          ),
                        ],
                        onChanged: (value) => setDialogState(
                          () => themeMode = value ?? ThemeMode.system,
                        ),
                      ),
                ),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'Destination template',
                    helperText:
                        'Tokens: {year}, {month}, {day}, {originalName}, {sourceFolder}',
                  ),
                ),
                StatefulBuilder(
                  builder: (context, setDialogState) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: splitRawAndJpeg,
                        title: const Text('Use separate JPEG and CRAW folders'),
                        onChanged: (value) => setDialogState(
                          () => splitRawAndJpeg = value ?? false,
                        ),
                      ),
                      if (splitRawAndJpeg) ...[
                        TextField(
                          controller: jpegController,
                          decoration: const InputDecoration(
                            labelText: 'JPEG destination template',
                          ),
                        ),
                        TextField(
                          controller: cr3Controller,
                          decoration: const InputDecoration(
                            labelText: 'CRAW destination template',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                StatefulBuilder(
                  builder: (context, setDialogState) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: vimKeys,
                    title: const Text('Vim navigation keys'),
                    subtitle: const Text(
                      'Use H, J, K, L to move between images',
                    ),
                    onChanged: (value) => setDialogState(() => vimKeys = value),
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
    if (saved != true ||
        controller.text.trim().isEmpty ||
        (splitRawAndJpeg &&
            (jpegController.text.trim().isEmpty ||
                cr3Controller.text.trim().isEmpty))) {
      return;
    }
    themeModeNotifier.value = themeMode;
    setState(() {
      _template = controller.text.trim();
      _splitRawAndJpeg = splitRawAndJpeg;
      _vimKeys = vimKeys;
      _jpegTemplate = jpegController.text.trim();
      _cr3Template = cr3Controller.text.trim();
      _shortcuts = {
        for (final decision in ReviewDecision.values)
          decision: keys[decision]!.text.trim().toUpperCase(),
      };
    });
    await _saveSettings();
    if (_source != null && !_scanning && !_ingesting) {
      unawaited(_refreshSourceListing());
    }
  }

  Future<void> _showLibrary() async {
    if (!mounted) return;
    final library = _library;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LibraryPage(
          libraryPath: library,
          media: _media,
          jpegRoot: library == null
              ? null
              : _splitRawAndJpeg
              ? _indexRoot(library, _jpegTemplate)
              : library,
          rawRoot: library == null
              ? null
              : _splitRawAndJpeg
              ? _indexRoot(library, _cr3Template)
              : library,
        ),
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.libraryPath,
    required this.media,
    this.jpegRoot,
    this.rawRoot,
  });

  final String? libraryPath;
  final MediaService media;
  final String? jpegRoot;
  final String? rawRoot;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<MediaFile> _assets = [];
  MediaSortOrder _sortOrder = MediaSortOrder.reviewDefault;
  bool _groupByDate = true;
  StreamSubscription<FileSystemEvent>? _libraryWatch;
  Timer? _refreshTimer;
  bool _loading = true;
  bool _refreshing = false;
  bool _refreshPending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _watchLibrary();
    unawaited(_refreshLibrary());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _libraryWatch?.cancel();
    super.dispose();
  }

  List<ReviewItem> get _orderedItems {
    final jpegByRelativePath = <String, MediaFile>{};
    final jpegByDirStem = <String, MediaFile>{};
    final jpegByStem = <String, MediaFile>{};
    for (final asset in _assets) {
      if (asset.kind != MediaKind.jpeg) continue;
      jpegByDirStem.putIfAbsent(_pairKey(asset.path), () => asset);
      jpegByStem.putIfAbsent(asset.stem, () => asset);
      final relative = _relativeToRoot(asset.path, widget.jpegRoot);
      if (relative != null) {
        jpegByRelativePath.putIfAbsent(relative, () => asset);
      }
    }

    final pairedJpegs = <String>{};
    final items = <ReviewItem>[];
    MediaFile? availableJpeg(Iterable<MediaFile?> candidates) {
      for (final candidate in candidates) {
        if (candidate != null && !pairedJpegs.contains(candidate.path)) {
          return candidate;
        }
      }
      return null;
    }

    for (final asset in _assets) {
      if (asset.kind != MediaKind.cr3) continue;
      final relative = _relativeToRoot(asset.path, widget.rawRoot);
      final jpeg = availableJpeg([
        if (relative != null) jpegByRelativePath[relative],
        jpegByDirStem[_pairKey(asset.path)],
        jpegByStem[asset.stem],
      ]);
      if (jpeg != null) pairedJpegs.add(jpeg.path);
      items.add(ReviewItem(jpeg: jpeg, cr3: asset));
    }

    for (final asset in _assets) {
      if (asset.kind == MediaKind.jpeg) {
        if (!pairedJpegs.contains(asset.path)) {
          items.add(ReviewItem(jpeg: asset));
        }
      } else if (asset.kind != MediaKind.cr3) {
        items.add(ReviewItem(single: asset));
      }
    }

    final order = MediaViewOrder.sortReviewItemIndices(items, _sortOrder);
    return [for (final index in order) items[index]];
  }

  Future<void> _watchLibrary() async {
    final library = widget.libraryPath;
    if (library == null || !await Directory(library).exists() || !mounted) {
      return;
    }
    try {
      _libraryWatch = Directory(library)
          .watch(recursive: true)
          .listen(
            (_) => _scheduleRefresh(),
            onError: (Object error) {
              debugPrint('[library] filesystem watch failed: $error');
            },
          );
    } on FileSystemException catch (error) {
      debugPrint('[library] could not watch library folder: $error');
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_refreshLibrary());
    });
  }

  Future<void> _refreshLibrary() async {
    final library = widget.libraryPath;
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    try {
      if (library == null) {
        if (mounted) {
          setState(() {
            _assets = [];
            _loading = false;
            _error = 'Choose a library folder to browse its media.';
          });
        }
        return;
      }
      final assets = await widget.media.listLibraryMedia(library);
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
        _error = null;
      });
    } on FileSystemException catch (error) {
      debugPrint('[library] scan failed: $error');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not read the selected library folder.';
        });
      }
    } finally {
      _refreshing = false;
      if (_refreshPending && mounted) {
        _refreshPending = false;
        _scheduleRefresh();
      }
    }
  }

  /// The path relative to [root], lowercased for case-insensitive cameras.
  String? _relativeToRoot(String filePath, String? root) {
    if (root == null) return null;
    final normalizedRoot = path.normalize(root);
    final normalizedFile = path.normalize(filePath);
    if (!path.isWithin(normalizedRoot, normalizedFile)) return null;
    return path
        .withoutExtension(path.relative(normalizedFile, from: normalizedRoot))
        .toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final items = _orderedItems;

    final groups = _groupByDate
        ? MediaViewOrder.groupByCaptureDate<ReviewItem>(
            items,
            (item) => item.captureDate,
            newestFirst: _sortOrder != MediaSortOrder.captureOldest,
          )
        : [MediaDateGroup(label: '', items: items)];
    final cacheWidth = (180 * MediaQuery.devicePixelRatioOf(context)).round();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          PopupMenuButton<MediaSortOrder>(
            tooltip: 'Sort library',
            icon: const Icon(Icons.sort),
            onSelected: (order) => setState(() => _sortOrder = order),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: MediaSortOrder.nameAscending,
                child: Text('Name (A–Z)'),
              ),
              PopupMenuItem(
                value: MediaSortOrder.nameDescending,
                child: Text('Name (Z–A)'),
              ),
              PopupMenuItem(
                value: MediaSortOrder.captureNewest,
                child: Text('Capture date (newest)'),
              ),
              PopupMenuItem(
                value: MediaSortOrder.captureOldest,
                child: Text('Capture date (oldest)'),
              ),
              PopupMenuItem(
                value: MediaSortOrder.sizeLargest,
                child: Text('File size (largest)'),
              ),
              PopupMenuItem(
                value: MediaSortOrder.sizeSmallest,
                child: Text('File size (smallest)'),
              ),
            ],
          ),
          IconButton(
            onPressed: () => setState(() => _groupByDate = !_groupByDate),
            icon: Icon(
              _groupByDate
                  ? Icons.calendar_month
                  : Icons.calendar_month_outlined,
            ),
            tooltip: _groupByDate ? 'Ungroup dates' : 'Group by date',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : items.isEmpty
          ? const Center(child: Text('No media files in this library folder.'))
          : CustomScrollView(
              slivers: [
                for (final group in groups) ...[
                  if (_groupByDate)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Text(
                          group.label,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                          ),
                      delegate: SliverChildBuilderDelegate((_, index) {
                        final item = group.items[index];
                        final asset = item.single ?? item.jpeg ?? item.cr3!;
                        final preview =
                            item.jpeg ??
                            (asset.kind == MediaKind.cr3 ? null : asset);
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    MediaPreview(
                                      preview: preview,
                                      cr3Path: item.cr3?.path,
                                      fit: BoxFit.cover,
                                      cacheWidth: cacheWidth,
                                      placeholder: const Center(
                                        child: Icon(
                                          Icons.perm_media_outlined,
                                          size: 48,
                                        ),
                                      ),
                                      loading: const SizedBox.shrink(),
                                      errorPlaceholder: const Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 8,
                                      top: 8,
                                      child: _formatBadges(item),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      item.isPair
                                          ? item.displayName
                                          : path.basename(asset.path),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${MediaViewOrder.captureDateLabel(item.captureDate)}  ·  '
                                      '${MediaViewOrder.sizeLabel(item.sizeBytes)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }, childCount: group.items.length),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  String _pairKey(String filePath) =>
      '${path.dirname(filePath).toLowerCase()}/'
      '${path.basenameWithoutExtension(filePath).toLowerCase()}';
}

/// A small, translucent label over a thumbnail, e.g. `JPEG` or `CR3`.
class _FormatBadge extends StatelessWidget {
  const _FormatBadge({
    required this.label,
    this.icon,
    this.tooltip,
    this.highlighted = false,
  });

  final String label;
  final IconData? icon;
  final String? tooltip;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final badge = DecoratedBox(
      decoration: BoxDecoration(
        color: highlighted
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.86)
            : Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white30, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 10, color: Colors.white),
              const SizedBox(width: 2),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
    final message = tooltip;
    return message == null ? badge : Tooltip(message: message, child: badge);
  }
}

Widget _formatBadges(ReviewItem item) {
  final formats = item.formats;
  final hasLibraryJpeg = item.existingJpeg != null;
  if (formats.isEmpty && !hasLibraryJpeg) {
    return const SizedBox.shrink();
  }
  final semantics = [
    if (formats.isNotEmpty) 'Formats: ${formats.join(', ')}',
    if (hasLibraryJpeg) 'JPEG already in library',
  ].join('. ');
  return Semantics(
    label: semantics,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < formats.length; index++) ...[
          if (index > 0) const SizedBox(width: 4),
          _FormatBadge(label: formats[index]),
        ],
        if (hasLibraryJpeg) ...[
          if (formats.isNotEmpty) const SizedBox(width: 4),
          const _FormatBadge(
            label: 'JPEG',
            icon: Icons.check,
            tooltip: 'JPEG already in library',
            highlighted: true,
          ),
        ],
      ],
    ),
  );
}

class _IngestProgress {
  const _IngestProgress({
    required this.phase,
    required this.done,
    required this.total,
    this.currentFile,
  });

  final String phase;
  final int done;
  final int total;
  final String? currentFile;

  double? get fraction => total == 0 ? null : done / total;
}

class _IngestProgressDialog extends StatelessWidget {
  const _IngestProgressDialog({required this.progress});

  final ValueListenable<_IngestProgress> progress;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Ingesting'),
    content: SizedBox(
      width: 380,
      child: ValueListenableBuilder<_IngestProgress>(
        valueListenable: progress,
        builder: (context, value, _) {
          final theme = Theme.of(context);
          final fraction = value.fraction;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value.phase, style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              TweenAnimationBuilder<double>(
                tween: Tween(end: fraction ?? 0),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                builder: (context, animated, _) => LinearProgressIndicator(
                  value: fraction == null ? null : animated,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      value.currentFile ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${value.done} / ${value.total}'
                    '${fraction == null ? '' : '  ·  ${(fraction * 100).round()}%'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}
