import '../../data/local/database.dart';
import '../notes/farkle_model.dart';
import '../notes/game_model.dart';

/// Pure plain-text rendering of a single note, for the "share as text" action.
/// Title on its own line, then the body, or the checklist as ☑/☐ lines. No
/// frontmatter or Markdown syntax — just readable text for a share sheet.
String buildNotePlainText({
  required NoteRow note,
  required List<ChecklistItemRow> items,
}) {
  final buf = StringBuffer();

  final title = note.title.trim();
  if (title.isNotEmpty) {
    buf.writeln(title);
    buf.writeln();
  }

  if (note.type == 'checklist') {
    final live = items.where((i) => !i.deleted).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    for (final item in live) {
      buf.writeln('${item.checked ? '☑' : '☐'} ${item.content}');
    }
  } else if (note.type == 'game') {
    buf.writeln(gamePlainText(parseGame(note.body)));
  } else if (note.type == 'farkle') {
    buf.writeln(farklePlainText(parseFarkle(note.body)));
  } else if (note.body.trim().isNotEmpty) {
    buf.writeln(note.body.trimRight());
  }

  return buf.toString().trimRight();
}
