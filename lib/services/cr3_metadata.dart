import 'dart:io';
import 'dart:typed_data';

import '../domain/capture_date.dart';

/// Canon's `uuid` box inside `moov`; it holds the `CMT1`..`CMT3` boxes, each a
/// standalone TIFF stream (IFD0, Exif IFD and GPS IFD respectively).
const _canonUuid = [
  0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0, //
  0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48,
];

const _maxMoovBytes = 4 * 1024 * 1024;

/// Capture date from the CR3 at [filePath], reading only the `moov` box.
/// Runs in a worker isolate, so it uses synchronous reads.
DateTime? readCr3CaptureDate(String filePath) {
  final file = File(filePath).openSync();
  try {
    final length = file.lengthSync();
    var offset = 0;
    while (offset + 8 <= length) {
      file.setPositionSync(offset);
      final header = file.readSync(16);
      final box = _readBoxHeader(header, 0, length - offset);
      if (box == null) return null;
      if (box.type == 'moov') {
        final payload = box.end - box.payloadStart;
        if (payload > _maxMoovBytes) return null;
        file.setPositionSync(offset + box.payloadStart);
        return cr3CaptureDateFromMoov(file.readSync(payload));
      }
      offset += box.end;
    }
  } finally {
    file.closeSync();
  }
  return null;
}

/// Capture date from the first bytes of a CR3, for sources that can't seek
/// (SAF). Needs `moov` to lie completely inside [head].
DateTime? cr3CaptureDateFromHead(Uint8List head) {
  for (final box in _boxes(head, 0, head.length)) {
    if (box.type == 'moov') {
      return cr3CaptureDateFromMoov(
        Uint8List.sublistView(head, box.payloadStart, box.end),
      );
    }
  }
  return null;
}

/// Capture date from the payload of a CR3 `moov` box.
DateTime? cr3CaptureDateFromMoov(Uint8List moov) {
  for (final box in _boxes(moov, 0, moov.length)) {
    if (box.type != 'uuid' ||
        box.end - box.payloadStart < 16 ||
        !_matches(moov, box.payloadStart, _canonUuid)) {
      continue;
    }
    Uint8List? ifd0;
    Uint8List? exif;
    for (final child in _boxes(moov, box.payloadStart + 16, box.end)) {
      final payload = Uint8List.sublistView(
        moov,
        child.payloadStart,
        child.end,
      );
      if (child.type == 'CMT1') ifd0 = payload;
      if (child.type == 'CMT2') exif = payload;
    }
    for (final tag in const [0x9003, 0x9004]) {
      final value = exif == null ? null : _tiffAscii(exif, tag);
      final date = value == null ? null : parseExifDate(value);
      if (date != null) return date;
    }
    final value = ifd0 == null ? null : _tiffAscii(ifd0, 0x0132);
    return value == null ? null : parseExifDate(value);
  }
  return null;
}

class _Box {
  const _Box(this.type, this.payloadStart, this.end);
  final String type;
  final int payloadStart;
  final int end;
}

/// Parses one ISO-BMFF box header at [start] in [bytes]. [available] is how
/// many bytes the box may span; larger or malformed sizes are rejected.
_Box? _readBoxHeader(Uint8List bytes, int start, int available) {
  if (bytes.length - start < 8) return null;
  final data = ByteData.sublistView(bytes);
  var size = data.getUint32(start);
  var headerLength = 8;
  if (size == 1) {
    if (bytes.length - start < 16) return null;
    size = data.getUint64(start + 8);
    headerLength = 16;
  } else if (size == 0) {
    size = available;
  }
  if (size < headerLength || size > available) return null;
  final type = String.fromCharCodes(bytes.sublist(start + 4, start + 8));
  return _Box(type, start + headerLength, start + size);
}

Iterable<_Box> _boxes(Uint8List bytes, int start, int end) sync* {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _readBoxHeader(bytes, offset, end - offset);
    if (box == null) return;
    yield box;
    offset = box.end;
  }
}

bool _matches(Uint8List bytes, int start, List<int> expected) {
  if (start + expected.length > bytes.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (bytes[start + index] != expected[index]) return false;
  }
  return true;
}

/// Reads an ASCII tag from IFD0 of a standalone TIFF stream.
String? _tiffAscii(Uint8List tiff, int tag) {
  try {
    if (tiff.length < 8) return null;
    final little = tiff[0] == 0x49 && tiff[1] == 0x49;
    if (!little && !(tiff[0] == 0x4d && tiff[1] == 0x4d)) return null;
    final endian = little ? Endian.little : Endian.big;
    final data = ByteData.sublistView(tiff);
    if (data.getUint16(2, endian) != 42) return null;
    final ifd = data.getUint32(4, endian);
    final count = data.getUint16(ifd, endian);
    for (var index = 0; index < count; index++) {
      final entry = ifd + 2 + index * 12;
      if (data.getUint16(entry, endian) != tag ||
          data.getUint16(entry + 2, endian) != 2) {
        continue;
      }
      final length = data.getUint32(entry + 4, endian);
      final start = length <= 4 ? entry + 8 : data.getUint32(entry + 8, endian);
      if (start + length > tiff.length) return null;
      final raw = tiff.sublist(start, start + length);
      final end = raw.indexOf(0);
      return String.fromCharCodes(end < 0 ? raw : raw.sublist(0, end));
    }
  } on RangeError {
    return null;
  }
  return null;
}
