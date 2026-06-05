import 'dart:async';

import 'package:drift/drift.dart' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import 'local/database.dart';
import 'notes_repository.dart';

/// Online-only [NotesRepository] for the web client. Reads/writes go directly
/// to PocketBase; the in-memory cache is kept live via realtime subscriptions.
/// There is no local persistence — if the server is unreachable the streams
/// surface an error (the UI shows a retry state).
class RemoteNotesRepository implements NotesRepository {
  RemoteNotesRepository(this._pb);

  final PocketBase _pb;

  final Map<String, NoteRow> _notes = {};
  final Map<String, ChecklistItemRow> _items = {};
  final Map<String, AttachmentRow> _attachments = {};

  final _events = StreamController<void>.broadcast();
  final List<UnsubscribeFunc> _unsubs = [];
  Future<void>? _loaded;

  String get _ownerId => _pb.authStore.record?.id ?? '';

  // ---------------- Loading + realtime ----------------

  /// Loads everything once and wires realtime. Rethrows connectivity errors so
  /// the watch streams emit an error.
  Future<void> _ensureLoaded() {
    return _loaded ??= _load();
  }

  Future<void> _load() async {
    final notes = await _pb.collection('notes').getFullList();
    for (final r in notes) {
      _notes[r.id] = _noteFrom(r);
    }
    final items = await _pb.collection('checklist_items').getFullList();
    for (final r in items) {
      _items[r.id] = _itemFrom(r);
    }
    final atts = await _pb.collection('attachments').getFullList();
    for (final r in atts) {
      _attachments[r.id] = _attachmentFrom(r, await _downloadBytes(r));
    }

    _unsubs.add(await _pb.collection('notes').subscribe('*', (e) {
      _applyEvent(e, _notes, (r) => _noteFrom(r));
    }));
    _unsubs.add(await _pb.collection('checklist_items').subscribe('*', (e) {
      _applyEvent(e, _items, (r) => _itemFrom(r));
    }));
    _unsubs.add(await _pb.collection('attachments').subscribe('*', (e) async {
      if (e.action == 'delete' || e.record == null) {
        if (e.record != null) _attachments.remove(e.record!.id);
      } else {
        final r = e.record!;
        // Download bytes only for newly-seen attachments.
        final existing = _attachments[r.id];
        final bytes = existing?.data ?? await _downloadBytes(r);
        _attachments[r.id] = _attachmentFrom(r, bytes);
      }
      _events.add(null);
    }));
  }

  void _applyEvent<T>(
    RecordSubscriptionEvent e,
    Map<String, T> store,
    T Function(RecordModel) build,
  ) {
    final r = e.record;
    if (r == null) return;
    if (e.action == 'delete') {
      store.remove(r.id);
    } else {
      store[r.id] = build(r);
    }
    _events.add(null);
  }

  /// A view stream: ensures loaded, emits the current computed value, then
  /// re-emits whenever anything changes.
  Stream<T> _view<T>(T Function() compute) async* {
    await _ensureLoaded();
    yield compute();
    yield* _events.stream.map((_) => compute());
  }

  // ---------------- Notes: queries ----------------

  List<NoteRow> _sorted(Iterable<NoteRow> ns, {bool pinnedFirst = true}) {
    final list = ns.toList();
    list.sort((a, b) {
      if (pinnedFirst && a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updated.compareTo(a.updated);
    });
    return list;
  }

  @override
  Stream<List<NoteRow>> watchActive() => _view(() => _sorted(
      _notes.values.where((n) => !n.deleted && !n.archived)));

  @override
  Stream<List<NoteRow>> watchArchived() => _view(() => _sorted(
      _notes.values.where((n) => !n.deleted && n.archived),
      pinnedFirst: false));

  @override
  Stream<List<NoteRow>> watchTrash() => _view(() => _sorted(
      _notes.values.where((n) => n.deleted), pinnedFirst: false));

  @override
  Stream<NoteRow?> watchNote(String id) => _view(() => _notes[id]);

  @override
  Stream<List<NoteRow>> searchActive(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return watchActive();
    bool itemMatch(String noteId) => _items.values.any((i) =>
        i.note == noteId && !i.deleted && i.content.toLowerCase().contains(q));
    return _view(() => _sorted(_notes.values.where((n) =>
        !n.deleted &&
        !n.archived &&
        (n.title.toLowerCase().contains(q) ||
            n.body.toLowerCase().contains(q) ||
            itemMatch(n.id)))));
  }

  // ---------------- Notes: mutations ----------------

  @override
  Future<String> createNote({required String type}) async {
    final r = await _pb.collection('notes').create(body: {
      'owner': _ownerId,
      'type': type,
      'title': '',
      'body': '',
      'pinned': false,
      'archived': false,
      'deleted': false,
    });
    _notes[r.id] = _noteFrom(r);
    _events.add(null);
    return r.id;
  }

  @override
  Future<void> updateNoteFields(String id, {String? title, String? body}) async {
    final r = await _pb.collection('notes').update(id, body: {
      'title': ?title,
      'body': ?body,
    });
    _notes[id] = _noteFrom(r);
    _events.add(null);
  }

  @override
  Future<void> setPinned(String id, bool pinned) =>
      _updateNote(id, {'pinned': pinned});

  @override
  Future<void> setArchived(String id, bool archived) =>
      _updateNote(id, {'archived': archived});

  @override
  Future<void> softDelete(String id) => _updateNote(id, {'deleted': true});

  @override
  Future<void> restore(String id) => _updateNote(id, {'deleted': false});

  Future<void> _updateNote(String id, Map<String, dynamic> body) async {
    final r = await _pb.collection('notes').update(id, body: body);
    _notes[id] = _noteFrom(r);
    _events.add(null);
  }

  @override
  Future<void> deleteForever(String noteId) async {
    await _pb.collection('notes').delete(noteId); // children cascade server-side
    _notes.remove(noteId);
    _items.removeWhere((_, v) => v.note == noteId);
    _attachments.removeWhere((_, v) => v.note == noteId);
    _events.add(null);
  }

  @override
  Future<List<String>> trashedNoteIds() async =>
      _notes.values.where((n) => n.deleted).map((n) => n.id).toList();

  @override
  Future<void> claimLocalNotes(String userId) async {/* no local notes on web */}

  // ---------------- Checklist items ----------------

  @override
  Stream<List<ChecklistItemRow>> watchItems(String noteId) => _view(() {
        final list = _items.values
            .where((i) => i.note == noteId && !i.deleted)
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));
        return list;
      });

  @override
  Future<String> addItem(String noteId, {String content = ''}) async {
    final maxPos = _items.values
        .where((i) => i.note == noteId && !i.deleted)
        .fold<int>(-1, (m, i) => i.position > m ? i.position : m);
    final r = await _pb.collection('checklist_items').create(body: {
      'note': noteId,
      'text': content,
      'checked': false,
      'position': maxPos + 1,
      'deleted': false,
    });
    _items[r.id] = _itemFrom(r);
    _events.add(null);
    return r.id;
  }

  @override
  Future<void> setItemContent(String id, String content) =>
      _updateItem(id, {'text': content});

  @override
  Future<void> setItemChecked(String id, bool checked) =>
      _updateItem(id, {'checked': checked});

  @override
  Future<void> deleteItem(String id) => _updateItem(id, {'deleted': true});

  Future<void> _updateItem(String id, Map<String, dynamic> body) async {
    final r = await _pb.collection('checklist_items').update(id, body: body);
    _items[id] = _itemFrom(r);
    _events.add(null);
  }

  // ---------------- Attachments ----------------

  @override
  Stream<List<AttachmentRow>> watchAttachments(String noteId) => _view(() {
        final list = _attachments.values
            .where((a) => a.note == noteId && !a.deleted)
            .toList()
          ..sort((a, b) => (a.created ?? '').compareTo(b.created ?? ''));
        return list;
      });

  @override
  Future<String> addAttachment(String noteId, Uint8List bytes) async {
    final r = await _pb.collection('attachments').create(
      body: {'note': noteId, 'deleted': false},
      files: [http.MultipartFile.fromBytes('file', bytes, filename: 'image.jpg')],
    );
    // We already have the bytes locally for immediate display.
    _attachments[r.id] = _attachmentFrom(r, bytes);
    _events.add(null);
    return r.id;
  }

  @override
  Future<void> deleteAttachment(String id) async {
    final r = await _pb.collection('attachments').update(id, body: {
      'deleted': true,
    });
    _attachments[id] = _attachmentFrom(r, _attachments[id]?.data);
    _events.add(null);
  }

  Future<Uint8List?> _downloadBytes(RecordModel rec) async {
    final filename = rec.getStringValue('file');
    if (filename.isEmpty) return null;
    try {
      final token = await _pb.files.getToken();
      final url = _pb.files.getUrl(rec, filename, token: token);
      final resp = await http.get(url);
      return resp.statusCode == 200 ? resp.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------- Mapping ----------------

  NoteRow _noteFrom(RecordModel r) => NoteRow(
        id: r.id,
        owner: r.getStringValue('owner'),
        type: r.getStringValue('type'),
        title: r.getStringValue('title'),
        body: r.getStringValue('body'),
        pinned: r.getBoolValue('pinned'),
        archived: r.getBoolValue('archived'),
        deleted: r.getBoolValue('deleted'),
        created: r.getStringValue('created'),
        updated: r.getStringValue('updated'),
        dirty: false,
      );

  ChecklistItemRow _itemFrom(RecordModel r) => ChecklistItemRow(
        id: r.id,
        note: r.getStringValue('note'),
        content: r.getStringValue('text'),
        checked: r.getBoolValue('checked'),
        position: r.getIntValue('position'),
        deleted: r.getBoolValue('deleted'),
        created: r.getStringValue('created'),
        updated: r.getStringValue('updated'),
        dirty: false,
      );

  AttachmentRow _attachmentFrom(RecordModel r, Uint8List? bytes) => AttachmentRow(
        id: r.id,
        note: r.getStringValue('note'),
        file: r.getStringValue('file'),
        data: bytes,
        deleted: r.getBoolValue('deleted'),
        created: r.getStringValue('created'),
        updated: r.getStringValue('updated'),
        dirty: false,
      );

  void dispose() {
    for (final u in _unsubs) {
      u();
    }
    _events.close();
  }
}
