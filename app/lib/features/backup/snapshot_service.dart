import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../../data/notes_repository.dart' show labelIdsOfRaw;
import 'v2/backup_preview.dart';

/// Client for the server-side snapshot (version history) feature. Talks to the
/// `snapshots` / `snapshot_settings` collections and the `/api/noteesek/...`
/// hook routes. Server-only: it requires a connected, signed-in account, so the
/// UI gates on authentication (no offline/local equivalent on mobile).
///
/// Snapshot files reuse the manual-backup JSON layout (BackupService format v1),
/// so a snapshot previews/parses with the same field shapes.
class SnapshotService {
  SnapshotService(this._pb);

  final PocketBase _pb;

  /// Reverse-chronological list of the account's snapshots.
  Future<List<SnapshotMeta>> list() async {
    final records =
        await _pb.collection('snapshots').getFullList(sort: '-created', batch: 200);
    return records.map(SnapshotMeta.fromRecord).toList();
  }

  /// The account's snapshot configuration, or defaults when no row exists yet.
  Future<SnapshotConfig> getConfig() async {
    try {
      final r = await _pb
          .collection('snapshot_settings')
          .getFirstListItem('owner = "$_uid"');
      return SnapshotConfig.fromRecord(r);
    } on ClientException catch (e) {
      if (e.statusCode == 404) return const SnapshotConfig();
      rethrow;
    }
  }

  /// Upsert the account's snapshot configuration (one row per user).
  Future<void> saveConfig(SnapshotConfig cfg) async {
    final body = {
      'owner': _uid,
      'enabled': cfg.enabled,
      'frequency': cfg.frequency,
      'retentionDays': cfg.retentionDays,
    };
    try {
      final existing = await _pb
          .collection('snapshot_settings')
          .getFirstListItem('owner = "$_uid"');
      await _pb.collection('snapshot_settings').update(existing.id, body: body);
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow;
      await _pb.collection('snapshot_settings').create(body: body);
    }
  }

  /// Take a snapshot immediately ("back up now").
  Future<void> createNow() async {
    await _pb.send('/api/noteesek/snapshots', method: 'POST');
  }

  /// Restore [id]. [mode] is `replace` (whole account → exactly this snapshot,
  /// trashing notes absent from it) or `notes` (only [noteIds], others left
  /// untouched).
  Future<void> restore(String id,
      {required String mode, List<String> noteIds = const []}) async {
    await _pb.send(
      '/api/noteesek/snapshots/$id/restore',
      method: 'POST',
      body: {'mode': mode, 'noteIds': noteIds},
    );
  }

  /// Delete a snapshot (server GC's any image blobs it solely referenced).
  Future<void> delete(String id) =>
      _pb.collection('snapshots').delete(id);

  /// Download and parse a snapshot's contents for read-only preview / note
  /// selection. The snapshot file is protected, so a short-lived token is used.
  Future<SnapshotContents> preview(String id) async {
    final rec = await _pb.collection('snapshots').getOne(id);
    final filename = rec.getStringValue('file');
    final token = await _pb.files.getToken();
    final url = _pb.files.getUrl(rec, filename, token: token);
    final resp = await http.get(url);
    if (resp.statusCode != 200) {
      throw Exception('Could not download snapshot ($filename)');
    }
    return SnapshotContents.parse(resp.bodyBytes);
  }

  String get _uid => _pb.authStore.record?.id ?? '';
}

/// Metadata about a single snapshot (for the list).
class SnapshotMeta {
  const SnapshotMeta({
    required this.id,
    required this.createdAt,
    required this.reason,
    required this.noteCount,
    required this.byteSize,
  });

  final String id;
  final DateTime createdAt;
  final String reason; // auto | manual | pre-restore
  final int noteCount;
  final int byteSize;

  factory SnapshotMeta.fromRecord(RecordModel r) => SnapshotMeta(
        id: r.id,
        createdAt:
            DateTime.tryParse(r.getStringValue('created'))?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
        reason: r.getStringValue('reason'),
        noteCount: r.getIntValue('noteCount'),
        byteSize: r.getIntValue('byteSize'),
      );
}

/// Per-account snapshot configuration.
class SnapshotConfig {
  const SnapshotConfig({
    this.enabled = false,
    this.frequency = 'daily',
    this.retentionDays = 14,
  });

  final bool enabled;
  final String frequency; // hourly | daily
  final int retentionDays;

  factory SnapshotConfig.fromRecord(RecordModel r) => SnapshotConfig(
        enabled: r.getBoolValue('enabled'),
        frequency:
            r.getStringValue('frequency').isEmpty ? 'daily' : r.getStringValue('frequency'),
        retentionDays:
            r.getIntValue('retentionDays') > 0 ? r.getIntValue('retentionDays') : 14,
      );

  SnapshotConfig copyWith({bool? enabled, String? frequency, int? retentionDays}) =>
      SnapshotConfig(
        enabled: enabled ?? this.enabled,
        frequency: frequency ?? this.frequency,
        retentionDays: retentionDays ?? this.retentionDays,
      );
}

/// A single note as captured in a snapshot (read-only preview).
class SnapshotNote {
  const SnapshotNote({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.deleted,
    required this.notebookId,
    required this.labelIds,
    required this.items,
    required this.imageCount,
  });

  final String id;
  final String type; // text | checklist
  final String title;
  final String body;
  final bool deleted;
  final String notebookId; // '' = no notebook
  final List<String> labelIds;
  final List<({String content, bool checked})> items;
  final int imageCount;

  /// A one-line preview snippet (body text, or the checklist items).
  String get snippet => type == 'checklist'
      ? items.map((e) => '${e.checked ? '☑' : '☐'} ${e.content}').join('  ')
      : body.trim();

  /// Title falling back to a body/checklist snippet, for the preview list.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    if (type == 'checklist' && items.isNotEmpty) return items.first.content;
    final firstLine = body.trim().split('\n').first;
    return firstLine.isEmpty ? '(untitled)' : firstLine;
  }
}

/// Parsed contents of a snapshot file.
class SnapshotContents {
  const SnapshotContents({required this.notes, required this.notebookNames});

  /// Active (non-deleted) notes, as they were at snapshot time.
  final List<SnapshotNote> notes;

  /// Notebook id → name, for grouping the preview.
  final Map<String, String> notebookNames;

  /// Notebook-grouped summaries in the same shape the backup-file restore
  /// preview uses, so both screens render an identical list. Snapshots carry no
  /// client-side thumbnails and are always verified server-side, so `thumb` is
  /// null and `damaged` is false.
  List<BackupNotebookGroup> toPreviewGroups() {
    final byNotebook = <String, List<BackupNoteSummary>>{};
    for (final n in notes) {
      final hasName = (notebookNames[n.notebookId] ?? '').isNotEmpty;
      final key = hasName ? n.notebookId : '';
      (byNotebook[key] ??= []).add(BackupNoteSummary(
        id: n.id,
        title: n.title.trim(),
        snippet: n.snippet,
        type: n.type,
        notebookId: key,
        thumb: null,
        damaged: false,
      ));
    }
    final groups = <BackupNotebookGroup>[];
    final namedKeys = byNotebook.keys.where((k) => k.isNotEmpty).toList()
      ..sort((a, b) => notebookNames[a]!
          .toLowerCase()
          .compareTo(notebookNames[b]!.toLowerCase()));
    for (final k in namedKeys) {
      groups.add(BackupNotebookGroup(
          notebookId: k, name: notebookNames[k]!, notes: byNotebook[k]!));
    }
    if (byNotebook.containsKey('')) {
      groups.add(BackupNotebookGroup(
          notebookId: '', name: 'No notebook', notes: byNotebook['']!));
    }
    return groups;
  }

  static SnapshotContents parse(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('Bad snapshot');
    final json = decoded.cast<String, dynamic>();

    List<Map<String, dynamic>> rows(String key) =>
        ((json[key] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

    // Group checklist items + attachment counts by note id.
    final itemsByNote = <String, List<({String content, bool checked})>>{};
    for (final m in rows('checklistItems')) {
      if (m['deleted'] == true) continue;
      (itemsByNote[m['note'] as String? ?? ''] ??= []).add((
        content: (m['content'] ?? '') as String,
        checked: (m['checked'] ?? false) as bool,
      ));
    }
    final imagesByNote = <String, int>{};
    for (final m in rows('attachments')) {
      if (m['deleted'] == true) continue;
      final note = m['note'] as String? ?? '';
      imagesByNote[note] = (imagesByNote[note] ?? 0) + 1;
    }
    final notebookNames = <String, String>{
      for (final m in rows('notebooks'))
        if (m['deleted'] != true)
          m['id'] as String: ((m['name'] ?? '') as String).trim(),
    };

    final notes = <SnapshotNote>[];
    for (final m in rows('notes')) {
      if (m['deleted'] == true) continue; // preview shows active notes only
      final id = m['id'] as String;
      notes.add(SnapshotNote(
        id: id,
        type: (m['type'] ?? 'text') as String,
        title: (m['title'] ?? '') as String,
        body: (m['body'] ?? '') as String,
        deleted: false,
        notebookId: (m['notebook'] ?? '') as String,
        labelIds: labelIdsOfRaw(m['labels'] as String? ?? '[]'),
        items: itemsByNote[id] ?? const [],
        imageCount: imagesByNote[id] ?? 0,
      ));
    }
    return SnapshotContents(notes: notes, notebookNames: notebookNames);
  }
}
