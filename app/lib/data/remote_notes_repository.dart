import 'dart:async';

import 'package:drift/drift.dart' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../ui/app_messenger.dart';
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
  final Map<String, LabelRow> _labels = {};
  final Map<String, NotebookRow> _notebooks = {};

  final _events = StreamController<void>.broadcast();
  final List<UnsubscribeFunc> _unsubs = [];
  Future<void>? _loaded;

  String get _ownerId => _pb.authStore.record?.id ?? '';

  // ---------------- Loading + realtime ----------------

  /// Loads everything once and wires realtime. Rethrows connectivity errors so
  /// the watch streams emit an error — and on failure clears the cached future
  /// so the next listen retries instead of being stuck on the dead attempt.
  Future<void> _ensureLoaded() {
    final existing = _loaded;
    if (existing != null) return existing;
    final fut = _load();
    _loaded = fut;
    // Don't cache a failed load: a transient outage shouldn't wedge the whole
    // UI in an error state forever. The awaiting _view still sees the error.
    fut.catchError((Object e) {
      if (identical(_loaded, fut)) _loaded = null;
    });
    return fut;
  }

  // ---------------- Error handling ----------------

  /// True for "can't reach the server" errors (offline, server down, DNS, TLS,
  /// timeout) as opposed to a real API error.
  static bool _isConnectivityError(Object e) {
    if (e is ClientException && e.statusCode == 0) return true;
    final s = e.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('connection refused') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('connection closed') ||
        s.contains('timed out') ||
        s.contains('timeout');
  }

  /// A short, user-facing description of a failed request.
  static String _friendly(Object e) {
    if (_isConnectivityError(e)) {
      return "Server not responding — change wasn't saved.";
    }
    if (e is ClientException) {
      final msg = e.response['message'];
      if (msg is String && msg.isNotEmpty) return msg;
      return 'Server error (${e.statusCode}) — change wasn\'t saved.';
    }
    return "Couldn't save — please try again.";
  }

  /// Runs a mutation, reporting any failure to the user via a SnackBar instead
  /// of letting it escape as an unhandled exception. Returns [fallback] on
  /// failure so the local cache is simply left untouched (realtime will
  /// reconcile if the write actually landed).
  Future<T> _guard<T>(Future<T> Function() op, T fallback) async {
    try {
      return await op();
    } catch (e) {
      showAppSnackBar(_friendly(e));
      return fallback;
    }
  }

  Future<void> _guardVoid(Future<void> Function() op) => _guard(op, null);

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
    final labels = await _pb.collection('labels').getFullList();
    for (final r in labels) {
      _labels[r.id] = _labelFrom(r);
    }
    final notebooks = await _pb.collection('notebooks').getFullList();
    for (final r in notebooks) {
      _notebooks[r.id] = _notebookFrom(r);
    }

    _unsubs.add(await _pb.collection('notes').subscribe('*', (e) {
      _applyEvent(e, _notes, (r) => _noteFrom(r));
    }));
    _unsubs.add(await _pb.collection('labels').subscribe('*', (e) {
      _applyEvent(e, _labels, (r) => _labelFrom(r));
    }));
    _unsubs.add(await _pb.collection('notebooks').subscribe('*', (e) {
      _applyEvent(e, _notebooks, (r) => _notebookFrom(r));
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
      return a.position.compareTo(b.position);
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
  Future<String> createNote({required String type, String notebook = ''}) =>
      _guard(() async {
        final maxPos = _notes.values
            .where((n) => !n.deleted)
            .fold<int>(-1, (m, n) => n.position > m ? n.position : m);
        final r = await _pb.collection('notes').create(body: {
          'owner': _ownerId,
          'type': type,
          'title': '',
          'body': '',
          'pinned': false,
          'archived': false,
          'deleted': false,
          'position': maxPos + 1,
          'notebook': notebook,
        });
        _notes[r.id] = _noteFrom(r);
        _events.add(null);
        return r.id;
      }, '');

  @override
  Future<String> importNote(NoteImport data) => _guard(() async {
        final maxPos = _notes.values
            .where((n) => !n.deleted)
            .fold<int>(-1, (m, n) => n.position > m ? n.position : m);
        final r = await _pb.collection('notes').create(body: {
          'owner': _ownerId,
          'type': data.type,
          'title': data.title,
          'body': data.body,
          'pinned': data.pinned,
          'archived': data.archived,
          'color': data.color,
          'labels': data.labelIds,
          'notebook': data.notebook,
          'deleted': false,
          'position': maxPos + 1,
        });
        _notes[r.id] = _noteFrom(r);

        for (var i = 0; i < data.items.length; i++) {
          final item = data.items[i];
          final ir = await _pb.collection('checklist_items').create(body: {
            'note': r.id,
            'text': item.content,
            'checked': item.checked,
            'position': i,
            'deleted': false,
          });
          _items[ir.id] = _itemFrom(ir);
        }

        for (final bytes in data.images) {
          final ar = await _pb.collection('attachments').create(
            body: {'note': r.id, 'deleted': false},
            files: [
              http.MultipartFile.fromBytes('file', bytes, filename: 'image.jpg')
            ],
          );
          _attachments[ar.id] = _attachmentFrom(ar, bytes);
        }

        _events.add(null);
        return r.id;
      }, '');

  @override
  Future<void> updateNoteFields(String id, {String? title, String? body}) =>
      _guardVoid(() async {
        final r = await _pb.collection('notes').update(id, body: {
          'title': ?title,
          'body': ?body,
        });
        _notes[id] = _noteFrom(r);
        _events.add(null);
      });

  @override
  Future<void> setPinned(String id, bool pinned) =>
      _updateNote(id, {'pinned': pinned});

  @override
  Future<void> setArchived(String id, bool archived) =>
      _updateNote(id, {'archived': archived});

  @override
  Future<void> setColor(String id, String color) =>
      _updateNote(id, {'color': color});

  @override
  Future<void> softDelete(String id) => _updateNote(id, {'deleted': true});

  @override
  Future<void> restore(String id) => _updateNote(id, {'deleted': false});

  Future<void> _updateNote(String id, Map<String, dynamic> body) =>
      _guardVoid(() async {
        final r = await _pb.collection('notes').update(id, body: body);
        _notes[id] = _noteFrom(r);
        _events.add(null);
      });

  @override
  Future<void> convertNoteType(String id, String type) => _guardVoid(() async {
    final note = _notes[id];
    if (note == null || note.type == type) return;

    if (type == 'checklist') {
      // Text → checklist: each non-blank body line becomes an item.
      final lines = note.body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      var pos = 0;
      for (final line in lines) {
        final r = await _pb.collection('checklist_items').create(body: {
          'note': id,
          'text': line,
          'checked': false,
          'position': pos++,
          'deleted': false,
        });
        _items[r.id] = _itemFrom(r);
      }
      final r = await _pb
          .collection('notes')
          .update(id, body: {'type': 'checklist', 'body': ''});
      _notes[id] = _noteFrom(r);
    } else {
      // Checklist → text: items become body lines (order preserved), then are
      // soft-deleted.
      final items = _items.values
          .where((i) => i.note == id && !i.deleted)
          .toList()
        ..sort((a, b) => a.position.compareTo(b.position));
      final body = items
          .map((i) => i.content.trim())
          .where((c) => c.isNotEmpty)
          .join('\n');
      for (final it in items) {
        final r = await _pb
            .collection('checklist_items')
            .update(it.id, body: {'deleted': true});
        _items[it.id] = _itemFrom(r);
      }
      final r = await _pb
          .collection('notes')
          .update(id, body: {'type': 'text', 'body': body});
      _notes[id] = _noteFrom(r);
    }
    _events.add(null);
  });

  @override
  Future<void> deleteForever(String noteId) => _guardVoid(() async {
        await _pb.collection('notes').delete(noteId); // children cascade
        _notes.remove(noteId);
        _items.removeWhere((_, v) => v.note == noteId);
        _attachments.removeWhere((_, v) => v.note == noteId);
        _events.add(null);
      });

  @override
  Future<List<String>> trashedNoteIds() async =>
      _notes.values.where((n) => n.deleted).map((n) => n.id).toList();

  @override
  Future<void> reorderNotes(List<String> orderedIds) => _guardVoid(() async {
        for (var i = 0; i < orderedIds.length; i++) {
          final r = await _pb
              .collection('notes')
              .update(orderedIds[i], body: {'position': i});
          _notes[orderedIds[i]] = _noteFrom(r);
        }
        _events.add(null);
      });

  @override
  Future<void> claimLocalNotes(String userId) async {/* no local notes on web */}

  @override
  Future<bool> hasForeignAccountData(String userId) async => false;

  // ---------------- Labels ----------------

  @override
  Stream<List<LabelRow>> watchLabels() => _view(() {
        final list = _labels.values.where((l) => !l.deleted).toList()
          ..sort((a, b) =>
              a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return list;
      });

  @override
  Future<String> createLabel(String name) => _guard(() async {
        final r = await _pb.collection('labels').create(body: {
          'owner': _ownerId,
          'name': name.trim(),
          'deleted': false,
        });
        _labels[r.id] = _labelFrom(r);
        _events.add(null);
        return r.id;
      }, '');

  @override
  Future<void> renameLabel(String id, String name) => _guardVoid(() async {
        final r = await _pb
            .collection('labels')
            .update(id, body: {'name': name.trim()});
        _labels[id] = _labelFrom(r);
        _events.add(null);
      });

  @override
  Future<void> setLabelColor(String id, String color) => _guardVoid(() async {
        final r =
            await _pb.collection('labels').update(id, body: {'color': color});
        _labels[id] = _labelFrom(r);
        _events.add(null);
      });

  @override
  Future<void> deleteLabel(String id) => _guardVoid(() async {
        final r =
            await _pb.collection('labels').update(id, body: {'deleted': true});
        _labels[id] = _labelFrom(r);
        // Strip the id from every note that carries it.
        for (final note in _notes.values.toList()) {
          final ids = labelIdsOf(note);
          if (ids.remove(id)) {
            await setNoteLabels(note.id, ids);
          }
        }
        _events.add(null);
      });

  @override
  Future<void> setNoteLabels(String noteId, List<String> labelIds) =>
      _guardVoid(() async {
        final r = await _pb
            .collection('notes')
            .update(noteId, body: {'labels': labelIds});
        _notes[noteId] = _noteFrom(r);
        _events.add(null);
      });

  // ---------------- Notebooks ----------------

  @override
  Stream<List<NotebookRow>> watchNotebooks() => _view(() {
        final list = _notebooks.values.where((n) => !n.deleted).toList()
          ..sort((a, b) => (a.created ?? '').compareTo(b.created ?? ''));
        return list;
      });

  @override
  Future<String> createNotebook(String name) => _guard(() async {
        final r = await _pb.collection('notebooks').create(body: {
          'owner': _ownerId,
          'name': name.trim(),
          'hidden_from_all': false,
          'deleted': false,
        });
        _notebooks[r.id] = _notebookFrom(r);
        _events.add(null);
        return r.id;
      }, '');

  @override
  Future<void> renameNotebook(String id, String name) => _guardVoid(() async {
        final r = await _pb
            .collection('notebooks')
            .update(id, body: {'name': name.trim()});
        _notebooks[id] = _notebookFrom(r);
        _events.add(null);
      });

  @override
  Future<void> setNotebookVisibility(String id, bool hidden) =>
      _guardVoid(() async {
        final r = await _pb
            .collection('notebooks')
            .update(id, body: {'hidden_from_all': hidden});
        _notebooks[id] = _notebookFrom(r);
        _events.add(null);
      });

  @override
  Future<void> deleteNotebook(String id, {required bool moveNotesToDefault}) =>
      _guardVoid(() async {
        final nb = _notebooks[id];
        if (nb == null) return;

        for (final note
            in _notes.values.where((n) => n.notebook == id).toList()) {
          if (moveNotesToDefault) {
            await setNoteNotebook(note.id, ''); // → no notebook
          } else {
            await softDelete(note.id);
          }
        }
        final r = await _pb
            .collection('notebooks')
            .update(id, body: {'deleted': true});
        _notebooks[id] = _notebookFrom(r);
        _events.add(null);
      });

  @override
  Future<void> setNoteNotebook(String noteId, String notebookId) =>
      _guardVoid(() async {
        final r = await _pb
            .collection('notes')
            .update(noteId, body: {'notebook': notebookId});
        _notes[noteId] = _noteFrom(r);
        _events.add(null);
      });

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
  Future<String> addItem(String noteId, {String content = ''}) =>
      _guard(() async {
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
      }, '');

  @override
  Future<void> setItemContent(String id, String content) =>
      _updateItem(id, {'text': content});

  @override
  Future<void> setItemChecked(String id, bool checked) =>
      _updateItem(id, {'checked': checked});

  @override
  Future<void> deleteItem(String id) => _updateItem(id, {'deleted': true});

  @override
  Future<void> reorderItems(List<String> orderedIds) => _guardVoid(() async {
        for (var i = 0; i < orderedIds.length; i++) {
          final r = await _pb
              .collection('checklist_items')
              .update(orderedIds[i], body: {'position': i});
          _items[orderedIds[i]] = _itemFrom(r);
        }
        _events.add(null);
      });

  Future<void> _updateItem(String id, Map<String, dynamic> body) =>
      _guardVoid(() async {
        final r =
            await _pb.collection('checklist_items').update(id, body: body);
        _items[id] = _itemFrom(r);
        _events.add(null);
      });

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
  Future<String> addAttachment(String noteId, Uint8List bytes) =>
      _guard(() async {
        final r = await _pb.collection('attachments').create(
          body: {'note': noteId, 'deleted': false},
          files: [
            http.MultipartFile.fromBytes('file', bytes, filename: 'image.jpg')
          ],
        );
        // We already have the bytes locally for immediate display.
        _attachments[r.id] = _attachmentFrom(r, bytes);
        _events.add(null);
        return r.id;
      }, '');

  @override
  Future<void> deleteAttachment(String id) => _guardVoid(() async {
        final r = await _pb.collection('attachments').update(id, body: {
          'deleted': true,
        });
        _attachments[id] = _attachmentFrom(r, _attachments[id]?.data);
        _events.add(null);
      });

  @override
  Stream<Set<String>> watchNoteIdsWithAttachments() => _view(() => _attachments
      .values
      .where((a) => !a.deleted)
      .map((a) => a.note)
      .toSet());

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
        color: r.getStringValue('color'),
        labels: encodeLabelIds(r.getListValue<String>('labels')),
        notebook: r.getStringValue('notebook'),
        lockedBy: r.getStringValue('lockedBy'),
        lockedAt: r.getStringValue('lockedAt'),
        deleted: r.getBoolValue('deleted'),
        created: r.getStringValue('created'),
        updated: r.getStringValue('updated'),
        dirty: false,
        position: r.getIntValue('position'),
      );

  NotebookRow _notebookFrom(RecordModel r) => NotebookRow(
        id: r.id,
        owner: r.getStringValue('owner'),
        name: r.getStringValue('name'),
        sharedWith: encodeLabelIds(r.getListValue<String>('sharedWith')),
        hiddenFromAll: r.getBoolValue('hidden_from_all'),
        deleted: r.getBoolValue('deleted'),
        created: r.getStringValue('created'),
        updated: r.getStringValue('updated'),
        dirty: false,
      );

  LabelRow _labelFrom(RecordModel r) => LabelRow(
        id: r.id,
        owner: r.getStringValue('owner'),
        name: r.getStringValue('name'),
        color: r.getStringValue('color'),
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
