import 'package:pocketbase/pocketbase.dart';

import 'local/ids.dart';
import 'local_notes_repository.dart';

/// A [LocalNotesRepository] whose **content edits go straight to the server**
/// instead of the local DB + sync. Used for a shared note open on mobile so its
/// text/checklist edits are server-authoritative and reach other clients in
/// real time (no local-first lag or divergence). The change comes back into the
/// local DB via the realtime subscription, which feeds the (inherited) read
/// streams — so the editor still reads from drift, it just no longer *writes*
/// the shared note's content there.
///
/// Only the high-frequency content writes are overridden; infrequent actions
/// (color, pin, labels, attachments, convert) keep the inherited local-first
/// behaviour.
class OnlineSharedNoteRepository extends LocalNotesRepository {
  OnlineSharedNoteRepository(super.db, super.ownerId, this._pb);

  final PocketBase _pb;

  @override
  Future<void> updateNoteFields(String id, {String? title, String? body}) async {
    final data = <String, dynamic>{};
    if (title != null) data['title'] = title;
    if (body != null) data['body'] = body;
    if (data.isNotEmpty) await _pb.collection('notes').update(id, body: data);
  }

  @override
  Future<String> addItem(String noteId, {String content = ''}) async {
    final items = await watchItems(noteId).first; // current (realtime-fed) order
    final maxPos =
        items.isEmpty ? -1 : items.map((e) => e.position).reduce((a, b) => a > b ? a : b);
    final id = newPbId();
    await _pb.collection('checklist_items').create(body: {
      'id': id,
      'note': noteId,
      'text': content,
      'position': maxPos + 1,
    });
    return id;
  }

  @override
  Future<void> setItemContent(String id, String content) async {
    await _pb.collection('checklist_items').update(id, body: {'text': content});
  }

  @override
  Future<void> setItemChecked(String id, bool checked) async {
    await _pb.collection('checklist_items').update(id, body: {'checked': checked});
  }

  @override
  Future<void> deleteItem(String id) async {
    await _pb.collection('checklist_items').update(id, body: {'deleted': true});
  }

  @override
  Future<void> reorderItems(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      await _pb.collection('checklist_items').update(orderedIds[i], body: {'position': i});
    }
  }

  /// Take a shared note out into a notebook I own, claiming ownership. Done in a
  /// single server-direct write *while still a member* so it can't be rejected
  /// by a racing unshare; the change comes back into drift via realtime (I keep
  /// access via the new `owner = me`). Once `owner` is mine the note detaches
  /// from the shared notebook for everyone else.
  @override
  Future<void> claimNoteToNotebook(String noteId, String notebookId) async {
    final me = _pb.authStore.record?.id;
    await _pb.collection('notes').update(noteId, body: {
      'notebook': notebookId,
      if (me != null && me.isNotEmpty) 'owner': me,
    });
  }
}
