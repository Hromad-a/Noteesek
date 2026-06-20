import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart' hide BackupService;

import '../../data/notes_repository.dart' show labelIdsOfRaw;
import 'backup_service.dart' show BackupService;
import 'v2/backup_v2.dart';
import 'v2/thumbnailer.dart';

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

  // ---- v2 (zip) format ----

  /// Gathers the signed-in account into the platform-agnostic v2 input,
  /// downloading attachment bytes via the protected-file token.
  Future<BackupInput> _gatherV2() async {
    final notes = await _pb.collection('notes').getFullList(batch: 500);
    final items =
        await _pb.collection('checklist_items').getFullList(batch: 500);
    final atts = await _pb.collection('attachments').getFullList(batch: 500);
    final labels = await _pb.collection('labels').getFullList(batch: 500);
    final notebooks = await _pb.collection('notebooks').getFullList(batch: 500);

    final itemsByNote = <String, List<RecordModel>>{};
    for (final i in items) {
      (itemsByNote[i.getStringValue('note')] ??= []).add(i);
    }
    final attByNote = <String, List<RecordModel>>{};
    final attBytes = <String, Uint8List?>{};
    for (final a in atts) {
      (attByNote[a.getStringValue('note')] ??= []).add(a);
      final fn = a.getStringValue('file');
      attBytes[a.id] = (fn.isEmpty || a.getBoolValue('deleted'))
          ? null
          : await _downloadFile(a, fn);
    }

    BackupItemInput item(RecordModel i) => BackupItemInput(
        id: i.id,
        text: i.getStringValue('text'),
        checked: i.getBoolValue('checked'),
        position: i.getIntValue('position'),
        deleted: i.getBoolValue('deleted'),
        created: i.getStringValue('created'),
        updated: i.getStringValue('updated'));

    return BackupInput(
      labels: [
        for (final l in labels)
          BackupLabelInput(
              id: l.id,
              name: l.getStringValue('name'),
              color: l.getStringValue('color'),
              deleted: l.getBoolValue('deleted'),
              created: l.getStringValue('created'),
              updated: l.getStringValue('updated')),
      ],
      notebooks: [
        for (final nb in notebooks)
          BackupNotebookInput(
              id: nb.id,
              name: nb.getStringValue('name'),
              deleted: nb.getBoolValue('deleted'),
              created: nb.getStringValue('created'),
              updated: nb.getStringValue('updated')),
      ],
      notes: [
        for (final n in notes)
          BackupNoteInput(
            id: n.id,
            type: n.getStringValue('type'),
            title: n.getStringValue('title'),
            body: n.getStringValue('body'),
            color: n.getStringValue('color'),
            pinned: n.getBoolValue('pinned'),
            archived: n.getBoolValue('archived'),
            deleted: n.getBoolValue('deleted'),
            position: n.getIntValue('position'),
            created: n.getStringValue('created'),
            updated: n.getStringValue('updated'),
            labelIds: n.getListValue<String>('labels'),
            notebookId: n.getStringValue('notebook'),
            items: [for (final i in (itemsByNote[n.id] ?? const [])) item(i)],
            attachments: [
              for (final a in (attByNote[n.id] ?? const []))
                BackupAttachmentInput(
                    id: a.id,
                    bytes: attBytes[a.id],
                    deleted: a.getBoolValue('deleted'),
                    created: a.getStringValue('created'),
                    updated: a.getStringValue('updated')),
            ],
          ),
      ],
    );
  }

  /// Exports the signed-in account as a v2 backup zip.
  Future<Uint8List> exportV2() async => writeBackupV2(await _gatherV2(), thumbnailer: makeThumbnail);

  /// Restores a v2 zip into the signed-in account (upsert by id; the owner-create
  /// hook stamps the account). Damaged entries are skipped; returns notes count.
  Future<int> importV2(Uint8List bytes) async {
    final r = BackupV2Reader.read(bytes);
    for (final nb in r.notebooks) {
      await _upsert('notebooks', nb['id'] as String,
          {'name': nb['name'] ?? '', 'deleted': nb['deleted'] ?? false});
    }
    for (final l in r.labels) {
      await _upsert('labels', l['id'] as String, {
        'name': l['name'] ?? '',
        'color': l['color'] ?? '',
        'deleted': l['deleted'] ?? false
      });
    }
    var count = 0;
    for (final idx in r.notes) {
      final rec = r.noteRecord(idx['id'] as String);
      if (rec == null) continue; // damaged → skip
      await _upsert('notes', rec['id'] as String, {
        'type': rec['type'] ?? 'text',
        'title': rec['title'] ?? '',
        'body': rec['body'] ?? '',
        'pinned': rec['pinned'] ?? false,
        'archived': rec['archived'] ?? false,
        'color': rec['color'] ?? '',
        'labels': (rec['labelIds'] as List?)?.cast<String>() ?? const [],
        'notebook': rec['notebookId'] ?? '',
        'deleted': rec['deleted'] ?? false,
        'position': rec['position'] ?? 0,
      });
      for (final i in ((rec['items'] as List?) ?? const [])) {
        final m = (i as Map).cast<String, dynamic>();
        await _upsert('checklist_items', m['id'] as String, {
          'note': rec['id'],
          'text': m['text'] ?? '',
          'checked': m['checked'] ?? false,
          'position': m['position'] ?? 0,
          'deleted': m['deleted'] ?? false,
        });
      }
      for (final a in ((rec['attachments'] as List?) ?? const [])) {
        final m = (a as Map).cast<String, dynamic>();
        final sha = m['sha256'] as String?;
        final ext = m['ext'] as String? ?? 'jpg';
        final deleted = m['deleted'] as bool? ?? false;
        await _putAttachment(m['id'] as String, rec['id'] as String, deleted,
            sha == null ? null : r.attachmentBytes(sha, ext));
      }
      count++;
    }
    return count;
  }

  /// Upsert one attachment from raw bytes (v2): update metadata, else create
  /// with a multipart upload.
  Future<void> _putAttachment(
      String id, String note, bool deleted, Uint8List? data) async {
    try {
      await _pb.collection('attachments').update(id, body: {'deleted': deleted});
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow;
      if (data == null) return; // missing/damaged bytes — skip
      await _pb.collection('attachments').create(
        body: {'id': id, 'note': note, 'deleted': deleted},
        files: [
          http.MultipartFile.fromBytes('file', data, filename: 'img_$id.jpg'),
        ],
      );
    }
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
