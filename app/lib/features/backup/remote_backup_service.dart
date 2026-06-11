import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart' hide BackupService;

import '../../data/notes_repository.dart' show labelIdsOfRaw;
import 'backup_service.dart' show BackupService;

/// Web counterpart to [BackupService]: a full backup/restore that talks to the
/// PocketBase API instead of a local drift DB (web has no local store). It
/// reads/writes the **same JSON layout** as [BackupService], so a file produced
/// on mobile can be restored on web and vice-versa.
///
/// Restore upserts by id (update, else create with the same id). Because the
/// owner-create hook forces `owner` to the signed-in user, a restored file lands
/// under the current account. Restoring a file from a *different account on the
/// same server* will collide on the shared, globally-unique ids — use it for
/// same-account restore or migrating onto a different/empty server.
class RemoteBackupService {
  RemoteBackupService(this._pb);

  final PocketBase _pb;

  Future<Uint8List> export() async {
    final notes = await _pb.collection('notes').getFullList(batch: 500);
    final items =
        await _pb.collection('checklist_items').getFullList(batch: 500);
    final attachments =
        await _pb.collection('attachments').getFullList(batch: 500);
    final labels = await _pb.collection('labels').getFullList(batch: 500);
    final notebooks = await _pb.collection('notebooks').getFullList(batch: 500);

    final data = <String, dynamic>{
      'format': BackupService.formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'notes': notes.map(_noteJson).toList(),
      'checklistItems': items.map(_itemJson).toList(),
      'attachments': [for (final a in attachments) await _attachmentJson(a)],
      'labels': labels.map(_labelJson).toList(),
      'notebooks': notebooks.map(_notebookJson).toList(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(data)));
  }

  /// Restores [bytes] into the signed-in account. Upserts every record by id and
  /// returns the number of notes restored. Throws [FormatException] on a
  /// malformed/incompatible file.
  Future<int> import(Uint8List bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['format'] != BackupService.formatVersion) {
      throw const FormatException('Not a Noteesek backup file');
    }
    final json = decoded.cast<String, dynamic>();
    List<Map<String, dynamic>> rows(String key) =>
        ((json[key] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

    // Parents before children so relations resolve.
    for (final m in rows('notebooks')) {
      await _upsert('notebooks', m['id'] as String, {
        'name': m['name'] ?? '',
        'deleted': m['deleted'] ?? false,
      });
    }
    for (final m in rows('labels')) {
      await _upsert('labels', m['id'] as String, {
        'name': m['name'] ?? '',
        'color': m['color'] ?? '',
        'deleted': m['deleted'] ?? false,
      });
    }
    final notes = rows('notes');
    for (final m in notes) {
      await _upsert('notes', m['id'] as String, {
        'type': m['type'] ?? 'text',
        'title': m['title'] ?? '',
        'body': m['body'] ?? '',
        'pinned': m['pinned'] ?? false,
        'archived': m['archived'] ?? false,
        'color': m['color'] ?? '',
        'labels': labelIdsOfRaw(m['labels'] as String? ?? '[]'),
        'notebook': m['notebook'] ?? '',
        'deleted': m['deleted'] ?? false,
        'position': m['position'] ?? 0,
      });
    }
    for (final m in rows('checklistItems')) {
      await _upsert('checklist_items', m['id'] as String, {
        'note': m['note'],
        'text': m['content'] ?? '',
        'checked': m['checked'] ?? false,
        'position': m['position'] ?? 0,
        'deleted': m['deleted'] ?? false,
      });
    }
    for (final m in rows('attachments')) {
      await _upsertAttachment(m);
    }
    return notes.length;
  }

  /// Update the record by id; if it doesn't exist, create it with the same id.
  Future<void> _upsert(
      String collection, String id, Map<String, dynamic> body) async {
    try {
      await _pb.collection(collection).update(id, body: body);
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow;
      await _pb.collection(collection).create(body: {'id': id, ...body});
    }
  }

  /// Attachments carry image bytes; (re)create with a multipart upload when the
  /// record doesn't exist yet, otherwise just sync the metadata.
  Future<void> _upsertAttachment(Map<String, dynamic> m) async {
    final id = m['id'] as String;
    final deleted = m['deleted'] as bool? ?? false;
    final dataB64 = m['data'] as String?;
    try {
      await _pb.collection('attachments').update(id, body: {'deleted': deleted});
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow;
      if (dataB64 == null) return; // no bytes to upload — skip
      await _pb.collection('attachments').create(
        body: {'id': id, 'note': m['note'], 'deleted': deleted},
        files: [
          http.MultipartFile.fromBytes('file', base64Decode(dataB64),
              filename: 'img_$id.jpg'),
        ],
      );
    }
  }

  // ---- record → json (same shape as BackupService) ----

  Map<String, dynamic> _noteJson(RecordModel n) => {
        'id': n.id,
        'owner': n.getStringValue('owner'),
        'type': n.getStringValue('type'),
        'title': n.getStringValue('title'),
        'body': n.getStringValue('body'),
        'pinned': n.getBoolValue('pinned'),
        'archived': n.getBoolValue('archived'),
        'color': n.getStringValue('color'),
        'labels': jsonEncode(n.getListValue<String>('labels')),
        'notebook': n.getStringValue('notebook'),
        'deleted': n.getBoolValue('deleted'),
        'created': n.getStringValue('created'),
        'updated': n.getStringValue('updated'),
        'position': n.getIntValue('position'),
      };

  Map<String, dynamic> _itemJson(RecordModel i) => {
        'id': i.id,
        'note': i.getStringValue('note'),
        'content': i.getStringValue('text'),
        'checked': i.getBoolValue('checked'),
        'position': i.getIntValue('position'),
        'deleted': i.getBoolValue('deleted'),
        'created': i.getStringValue('created'),
        'updated': i.getStringValue('updated'),
      };

  Future<Map<String, dynamic>> _attachmentJson(RecordModel a) async {
    final filename = a.getStringValue('file');
    String? dataB64;
    if (filename.isNotEmpty && !a.getBoolValue('deleted')) {
      final bytes = await _downloadFile(a, filename);
      if (bytes != null) dataB64 = base64Encode(bytes);
    }
    return {
      'id': a.id,
      'note': a.getStringValue('note'),
      'file': filename,
      'data': dataB64,
      'deleted': a.getBoolValue('deleted'),
      'created': a.getStringValue('created'),
      'updated': a.getStringValue('updated'),
    };
  }

  Map<String, dynamic> _labelJson(RecordModel l) => {
        'id': l.id,
        'owner': l.getStringValue('owner'),
        'name': l.getStringValue('name'),
        'color': l.getStringValue('color'),
        'deleted': l.getBoolValue('deleted'),
        'created': l.getStringValue('created'),
        'updated': l.getStringValue('updated'),
      };

  Map<String, dynamic> _notebookJson(RecordModel n) => {
        'id': n.id,
        'owner': n.getStringValue('owner'),
        'name': n.getStringValue('name'),
        'deleted': n.getBoolValue('deleted'),
        'created': n.getStringValue('created'),
        'updated': n.getStringValue('updated'),
      };

  Future<Uint8List?> _downloadFile(RecordModel rec, String filename) async {
    try {
      final token = await _pb.files.getToken();
      final url = _pb.files.getUrl(rec, filename, token: token);
      final resp = await http.get(url);
      return resp.statusCode == 200 ? resp.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }
}
