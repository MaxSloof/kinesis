import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:saf/saf.dart';

/// Small Android-only adapter for the Storage Access Framework.
///
/// SAF document URIs are opaque identifiers, not filesystem paths. Keep them
/// intact and use this adapter instead of passing them to `File`/`Directory`.
class SafStorage {
  SafStorage._();

  static final SafStorage instance = SafStorage._();
  final Saf _saf = Saf();

  static bool isUri(String value) =>
      Uri.tryParse(value)?.scheme.toLowerCase() == 'content';

  Future<String?> pickDirectory({String? initialUri}) async {
    final directory = await _saf.pickDirectory(initialUri: initialUri);
    return directory?.uri;
  }

  Stream<SafWalkEntry> walk(String uri) => _saf.walk(uri);

  Future<String> hashFile(String uri) async {
    final stream = await _saf.readFileStream(uri);
    return (await sha256.bind(stream).first).toString();
  }

  Future<Uint8List> readHead(String uri, int bytes) =>
      _saf.readFileBytes(uri, start: 0, count: bytes);

  Future<bool> exists(String uri) => _saf.exists(uri);

  Future<SafDocumentFile?> stat(String uri) => _saf.stat(uri);

  Future<SafDocumentFile> mkdirp(String uri, List<String> segments) =>
      _saf.mkdirp(uri, segments);

  Future<List<SafDocumentFile>> list(String uri) => _saf.list(uri);

  Future<SafDocumentFile?> child(String uri, List<String> segments) =>
      _saf.child(uri, segments);

  Future<SafDocumentFile> copyVerified({
    required String sourceUri,
    required String destinationDirectoryUri,
    required String name,
    required String mimeType,
    required String expectedHash,
  }) async {
    final source = await _saf.readFileStream(sourceUri);
    final destination = await _saf.writeFileStream(
      destinationDirectoryUri,
      name,
      mimeType,
      source,
    );
    try {
      if (await hashFile(destination.uri) != expectedHash) {
        throw FileSystemException('Copied bytes did not verify', sourceUri);
      }
      return destination;
    } on Object {
      await _saf.delete(destination.uri);
      rethrow;
    }
  }

  Future<void> moveToTrash({
    required String rootUri,
    required String fileUri,
    required String relativePath,
  }) async {
    final parent = relativePath.contains('/')
        ? relativePath.substring(0, relativePath.lastIndexOf('/'))
        : '';
    final segments = <String>[
      '.kinesis-trash',
      DateTime.now().toIso8601String().substring(0, 10),
      if (parent.isNotEmpty) ...parent.split('/'),
    ];
    final destination = await _saf.mkdirp(rootUri, segments);
    await _saf.moveTo(fileUri, destination.uri);
  }

  Future<Uint8List?> thumbnail(String uri) =>
      _saf.thumbnail(uri, 1600, 1600, 90);

  Future<File> copyToCache(String uri, String destination) async {
    await _saf.copyToLocalFile(uri, destination);
    return File(destination);
  }
}
