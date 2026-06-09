import 'dart:io';
import 'dart:typed_data';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../data/notes_repository.dart';

/// Turns content shared into the app (Android share sheet → Noteesek) into a new
/// note. Shared text/links become the body; shared images become attachments.
/// Mobile only.
class QuickCapture {
  /// Creates a note from [media]. Returns the new note id, or null if nothing
  /// usable was shared (or the write failed).
  static Future<String?> createNote(
    NotesRepository repo,
    List<SharedMediaFile> media,
  ) async {
    if (media.isEmpty) return null;

    final texts = <String>[];
    final images = <Uint8List>[];
    for (final m in media) {
      switch (m.type) {
        case SharedMediaType.text:
        case SharedMediaType.url:
          if (m.path.trim().isNotEmpty) texts.add(m.path.trim());
        case SharedMediaType.image:
          try {
            images.add(await File(m.path).readAsBytes());
          } catch (_) {/* skip unreadable file */}
        case SharedMediaType.video:
        case SharedMediaType.file:
          break; // no generic file attachments yet
      }
    }
    if (texts.isEmpty && images.isEmpty) return null;

    final id = await repo.createNote(type: 'text');
    if (id.isEmpty) return null; // web/server-unreachable guard
    if (texts.isNotEmpty) {
      await repo.updateNoteFields(id, body: texts.join('\n\n'));
    }
    for (final bytes in images) {
      await repo.addAttachment(id, bytes);
    }
    return id;
  }
}
