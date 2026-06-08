import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The set of note ids currently multi-selected on the notes grid.
///
/// An empty set means selection mode is off. Long-pressing a card enters
/// selection mode (adds its id); tapping cards while in selection mode toggles
/// them. The contextual action bar in [NotesScreen] reads this to act on the
/// whole selection at once.
class NoteSelectionNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String id) => state = {...state, id};

  void toggle(String id) {
    final next = {...state};
    if (!next.remove(id)) next.add(id);
    state = next;
  }

  bool isSelected(String id) => state.contains(id);

  void clear() {
    if (state.isNotEmpty) state = const {};
  }

  void selectAll(Iterable<String> ids) => state = {...ids};
}

final noteSelectionProvider =
    NotifierProvider<NoteSelectionNotifier, Set<String>>(
        NoteSelectionNotifier.new);

/// True when any notes are selected (the action bar is showing).
final selectionModeProvider =
    Provider<bool>((ref) => ref.watch(noteSelectionProvider).isNotEmpty);
