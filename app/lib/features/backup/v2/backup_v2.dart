import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Backup format **v2** — a fault-isolated, previewable zip (see
/// docs/backup-format-v2.md). This file is the pure, platform-agnostic core:
/// it turns in-memory [BackupInput] into a v2 zip ([writeBackupV2]) and reads a
/// v2 zip back ([BackupV2Reader]) with per-entry integrity verification. It has
/// no Flutter/drift/PocketBase deps, so mobile and web both feed it and it is
/// fully unit-testable.
const int kBackupV2Format = 2;

// ----------------------------- input models -----------------------------

class BackupInput {
  BackupInput({
    required this.notes,
    required this.labels,
    required this.notebooks,
    this.backgrounds = const [],
    this.app = '',
  });
  final List<BackupNoteInput> notes;
  final List<BackupLabelInput> labels;
  final List<BackupNotebookInput> notebooks;
  final List<BackupBackgroundInput> backgrounds;
  final String app;
}

class BackupNoteInput {
  BackupNoteInput({
    required this.id,
    required this.type,
    this.title = '',
    this.body = '',
    this.color = '',
    this.pinned = false,
    this.archived = false,
    this.deleted = false,
    this.position = 0,
    this.created,
    this.updated,
    this.labelIds = const [],
    this.notebookId = '',
    this.background = '',
    this.items = const [],
    this.attachments = const [],
  });
  final String id;
  final String type; // text | checklist
  final String title;
  final String body;
  final String color;
  final String background;
  final bool pinned;
  final bool archived;
  final bool deleted;
  final int position;
  final String? created;
  final String? updated;
  final List<String> labelIds;
  final String notebookId;
  final List<BackupItemInput> items;
  final List<BackupAttachmentInput> attachments;
}

class BackupItemInput {
  BackupItemInput({
    required this.id,
    this.text = '',
    this.checked = false,
    this.position = 0,
    this.deleted = false,
    this.created,
    this.updated,
  });
  final String id;
  final String text;
  final bool checked;
  final int position;
  final bool deleted;
  final String? created;
  final String? updated;
}

class BackupAttachmentInput {
  BackupAttachmentInput({
    required this.id,
    this.ext = 'jpg',
    this.mime = 'image/jpeg',
    this.deleted = false,
    this.created,
    this.updated,
    this.bytes,
  });
  final String id;
  final String ext;
  final String mime;
  final bool deleted;
  final String? created;
  final String? updated;

  /// Raw image bytes. Null for a deleted attachment or one whose bytes couldn't
  /// be fetched — then no file is written, only metadata.
  final Uint8List? bytes;
}

/// A background library entry (image + display options). Bytes are content-
/// addressed like attachments.
class BackupBackgroundInput {
  BackupBackgroundInput({
    required this.id,
    this.name = '',
    this.ext = 'jpg',
    this.mime = 'image/jpeg',
    this.opacity = 1,
    this.overlayColor = '',
    this.overlayOpacity = 0,
    this.fit = 'cover',
    this.repeat = 'none',
    this.scale = 1,
    this.deleted = false,
    this.created,
    this.updated,
    this.bytes,
  });
  final String id;
  final String name;
  final String ext;
  final String mime;
  final double opacity;
  final String overlayColor;
  final double overlayOpacity;
  final String fit;
  final String repeat;
  final double scale;
  final bool deleted;
  final String? created;
  final String? updated;
  final Uint8List? bytes;
}

/// Produces a small preview thumbnail (e.g. JPEG bytes) from full image bytes,
/// or null to skip. Supplied by the UI layer (keeps the image codec dep out of
/// this pure core). Returns the thumbnail bytes and the extension to use.
typedef Thumbnailer = Future<(Uint8List bytes, String ext)?> Function(
    Uint8List source, String mime);

// ------------------------------- writer ---------------------------------

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String _snippet(BackupNoteInput n) {
  final raw = n.type == 'checklist'
      ? n.items.where((i) => !i.deleted).map((i) => i.text).join(', ')
      : n.body;
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 140 ? flat : '${flat.substring(0, 139)}…';
}

/// Builds a v2 backup zip from [input]. Attachments are content-addressed
/// (`attachments/<sha256>.<ext>`) and deduplicated by hash. When [thumbnailer]
/// is given, a `thumbs/<sha256>.<ext>` is written per image for fast preview.
Future<Uint8List> writeBackupV2(
  BackupInput input, {
  Thumbnailer? thumbnailer,
  DateTime? now,
}) async {
  final archive = Archive();
  final files = <String, String>{}; // path -> sha256 (integrity registry)
  final blobsSeen = <String>{}; // attachment sha256 already written
  final thumbsSeen = <String>{};

  void addEntry(String path, List<int> bytes, {bool compress = true}) {
    final af = ArchiveFile(path, bytes.length, bytes);
    if (!compress) af.compression = CompressionType.none; // already-compressed
    archive.addFile(af);
    files[path] = _sha256Hex(bytes);
  }

  final noteIndex = <Map<String, dynamic>>[];

  for (final n in input.notes) {
    // Resolve attachment bytes → content hashes; write each blob once.
    final attMeta = <Map<String, dynamic>>[];
    final idxAtt = <Map<String, dynamic>>[];
    for (final a in n.attachments) {
      String? sha;
      String? thumbPath;
      if (a.bytes != null && a.bytes!.isNotEmpty && !a.deleted) {
        sha = _sha256Hex(a.bytes!);
        final blobPath = 'attachments/$sha.${a.ext}';
        if (blobsSeen.add(sha)) {
          addEntry(blobPath, a.bytes!, compress: false); // already compressed
          final thumb = await thumbnailer?.call(a.bytes!, a.mime);
          if (thumb != null && thumbsSeen.add(sha)) {
            thumbPath = 'thumbs/$sha.${thumb.$2}';
            addEntry(thumbPath, thumb.$1, compress: false);
          }
        } else {
          thumbPath = thumbsSeen.contains(sha) ? 'thumbs/$sha' : null;
        }
      }
      final meta = <String, dynamic>{
        'id': a.id,
        'ext': a.ext,
        'mime': a.mime,
        'deleted': a.deleted,
        'created': a.created,
        'updated': a.updated,
      };
      if (a.bytes != null) meta['bytes'] = a.bytes!.length;
      if (sha != null) meta['sha256'] = sha;
      attMeta.add(meta);

      final idx = <String, dynamic>{'id': a.id};
      if (sha != null) idx['sha256'] = sha;
      if (thumbPath != null) idx['thumb'] = thumbPath;
      idxAtt.add(idx);
    }

    final noteJson = <String, dynamic>{
      'id': n.id,
      'type': n.type,
      'title': n.title,
      'body': n.body,
      'color': n.color,
      'pinned': n.pinned,
      'archived': n.archived,
      'deleted': n.deleted,
      'position': n.position,
      'created': n.created,
      'updated': n.updated,
      'labelIds': n.labelIds,
      'notebookId': n.notebookId,
      'background': n.background,
      'items': [
        for (final i in n.items)
          {
            'id': i.id,
            'text': i.text,
            'checked': i.checked,
            'position': i.position,
            'deleted': i.deleted,
            'created': i.created,
            'updated': i.updated,
          }
      ],
      'attachments': attMeta,
    };
    final notePath = 'notes/${n.id}.json';
    addEntry(notePath, utf8.encode(jsonEncode(noteJson)));

    noteIndex.add({
      'id': n.id,
      'file': notePath,
      'title': n.title,
      'snippet': _snippet(n),
      'type': n.type,
      'color': n.color,
      'pinned': n.pinned,
      'archived': n.archived,
      'deleted': n.deleted,
      'labelIds': n.labelIds,
      'notebookId': n.notebookId,
      'background': n.background,
      'created': n.created,
      'updated': n.updated,
      'attachments': idxAtt,
    });
  }

  // Backgrounds: content-address bytes (`backgrounds/<sha>.<ext>`), dedup, and
  // record options + the hash in the manifest.
  final bgSeen = <String>{};
  final bgMeta = <Map<String, dynamic>>[];
  for (final b in input.backgrounds) {
    String? sha;
    if (b.bytes != null && b.bytes!.isNotEmpty && !b.deleted) {
      sha = _sha256Hex(b.bytes!);
      if (bgSeen.add(sha)) {
        addEntry('backgrounds/$sha.${b.ext}', b.bytes!, compress: false);
      }
    }
    final meta = <String, dynamic>{
      'id': b.id,
      'name': b.name,
      'ext': b.ext,
      'mime': b.mime,
      'opacity': b.opacity,
      'overlayColor': b.overlayColor,
      'overlayOpacity': b.overlayOpacity,
      'fit': b.fit,
      'repeat': b.repeat,
      'scale': b.scale,
      'deleted': b.deleted,
      'created': b.created,
      'updated': b.updated,
    };
    if (sha != null) meta['sha256'] = sha;
    bgMeta.add(meta);
  }

  final manifest = <String, dynamic>{
    'format': kBackupV2Format,
    'app': input.app,
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'counts': {
      'notes': input.notes.length,
      'attachments': blobsSeen.length,
      'labels': input.labels.length,
      'notebooks': input.notebooks.length,
      'backgrounds': bgSeen.length,
    },
    'labels': [
      for (final l in input.labels)
        {
          'id': l.id,
          'name': l.name,
          'color': l.color,
          'deleted': l.deleted,
          'created': l.created,
          'updated': l.updated,
        }
    ],
    'notebooks': [
      for (final nb in input.notebooks)
        {
          'id': nb.id,
          'name': nb.name,
          'deleted': nb.deleted,
          'created': nb.created,
          'updated': nb.updated,
        }
    ],
    'backgrounds': bgMeta,
    'notes': noteIndex,
    'files': files,
  };

  final manifestBytes = utf8.encode(jsonEncode(manifest));
  // The manifest is the linchpin for preview/selective import → store it twice
  // (L1). It is NOT listed in `files` (it can't checksum itself).
  archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  archive.addFile(
      ArchiveFile('manifest.bak.json', manifestBytes.length, manifestBytes));

  final out = ZipEncoder().encode(archive);
  return Uint8List.fromList(out);
}

class BackupLabelInput {
  BackupLabelInput(
      {required this.id,
      this.name = '',
      this.color = '',
      this.deleted = false,
      this.created,
      this.updated});
  final String id;
  final String name;
  final String color;
  final bool deleted;
  final String? created;
  final String? updated;
}

class BackupNotebookInput {
  BackupNotebookInput(
      {required this.id,
      this.name = '',
      this.deleted = false,
      this.created,
      this.updated});
  final String id;
  final String name;
  final bool deleted;
  final String? created;
  final String? updated;
}

// ------------------------------- reader ---------------------------------

/// Thrown when the input isn't a recognisable v2 backup (no usable manifest).
class BackupV2FormatException implements Exception {
  BackupV2FormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupV2FormatException: $message';
}

/// Reads a v2 backup zip: exposes the manifest (preview index) and verifies /
/// extracts individual entries, so a single corrupt entry never blocks the
/// rest (fault isolation).
class BackupV2Reader {
  BackupV2Reader._(this._archive, this.manifest);

  final Archive _archive;
  final Map<String, dynamic> manifest;

  static BackupV2Reader read(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    Map<String, dynamic>? parse(String name) {
      final f = archive.findFile(name);
      if (f == null) return null;
      try {
        final decoded = jsonDecode(utf8.decode(f.content as List<int>));
        return decoded is Map<String, dynamic>
            ? decoded
            : (decoded as Map).cast<String, dynamic>();
      } catch (_) {
        return null;
      }
    }

    // L1: fall back to the duplicate manifest if the primary is corrupt.
    final m = parse('manifest.json') ?? parse('manifest.bak.json');
    if (m == null || m['format'] != kBackupV2Format) {
      throw BackupV2FormatException('not a v2 backup (no valid manifest)');
    }
    return BackupV2Reader._(archive, m);
  }

  Map<String, String> get _files =>
      (manifest['files'] as Map?)?.cast<String, String>() ?? const {};

  List<Map<String, dynamic>> get notes =>
      ((manifest['notes'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  List<Map<String, dynamic>> get labels =>
      ((manifest['labels'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  List<Map<String, dynamic>> get notebooks =>
      ((manifest['notebooks'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  List<Map<String, dynamic>> get backgrounds =>
      ((manifest['backgrounds'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  Uint8List? entryBytes(String path) {
    final f = _archive.findFile(path);
    return f == null ? null : Uint8List.fromList(f.content as List<int>);
  }

  /// True when [path] exists and its bytes match the manifest's SHA-256.
  bool verifyEntry(String path) {
    final expected = _files[path];
    final bytes = entryBytes(path);
    if (expected == null || bytes == null) return false;
    return _sha256Hex(bytes) == expected;
  }

  /// Every entry path in the manifest that is missing or fails its checksum.
  List<String> damagedEntries() =>
      [for (final p in _files.keys) if (!verifyEntry(p)) p];

  /// The parsed `notes/<id>.json` for [noteId], or null if missing/corrupt.
  Map<String, dynamic>? noteRecord(String noteId) {
    final path = 'notes/$noteId.json';
    if (!verifyEntry(path)) return null;
    try {
      return (jsonDecode(utf8.decode(entryBytes(path)!)) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Verified image bytes for a content hash, or null if missing/corrupt.
  Uint8List? attachmentBytes(String sha256, String ext) {
    final path = 'attachments/$sha256.$ext';
    return verifyEntry(path) ? entryBytes(path) : null;
  }

  /// Verified background image bytes for a content hash, or null.
  Uint8List? backgroundBytes(String sha256, String ext) {
    final path = 'backgrounds/$sha256.$ext';
    return verifyEntry(path) ? entryBytes(path) : null;
  }
}
