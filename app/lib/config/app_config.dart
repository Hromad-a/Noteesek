import 'package:flutter/foundation.dart' show kIsWeb;

/// Static configuration and persisted-preference keys.
class AppConfig {
  /// Default PocketBase server URL prefilled on the Connect screen. Editable and
  /// persisted. On the web build (which is served *by* the server itself), this
  /// defaults to the page's own origin so it works out of the box; on mobile it
  /// falls back to localhost.
  static String defaultServerUrl() =>
      kIsWeb ? Uri.base.origin : 'http://localhost:8090';

  /// Owner tag for notes created while not connected to a server. These are
  /// "claimed" (reassigned to the account) when the user connects.
  static const String localOwner = 'local';

  // shared_preferences keys
  static const String kServerUrl = 'server_url';
  static const String kPbAuth = 'pb_auth';
  static const String kActiveOwner = 'active_owner';

  /// Id of the notebook currently shown in the grid (persists the user's last
  /// selection). Empty falls back to the default notebook.
  static const String kSelectedNotebook = 'selected_notebook';

  /// Grid layout: 'grid' (multi-column masonry) or 'column' (single column).
  static const String kNoteViewMode = 'note_view_mode';

  /// Note sort: field ('custom' | 'edited' | 'created') and direction.
  static const String kNoteSortField = 'note_sort_field';
  static const String kNoteSortAscending = 'note_sort_ascending';

  /// App theme: 'system' | 'light' | 'dark'. Drives MaterialApp.themeMode.
  static const String kThemeMode = 'theme_mode';

  /// Checklist editor: when true, checked items sink to a collapsible
  /// "completed" section at the bottom (Google Keep-style).
  static const String kChecklistAutoSort = 'checklist_auto_sort';

  /// Notebook ids the user has personally hidden from "All notes" (a local,
  /// per-user preference — JSON id array). Used for shared notebooks a member
  /// doesn't own (they can't write the owner's global `hidden_from_all`).
  static const String kLocallyHiddenNotebooks = 'locally_hidden_notebooks';

  /// Whether the one-time "how shared notebooks work" explainer has been shown
  /// (on first opening the share sheet).
  static const String kSharedNotebookIntroSeen = 'shared_notebook_intro_seen';

  /// App lock (mobile): whether the lock is on, and whether biometric unlock is
  /// allowed. The PIN hash itself lives in secure storage, not here.
  static const String kAppLockEnabled = 'app_lock_enabled';
  static const String kAppLockBiometric = 'app_lock_biometric';

  /// Render note bodies as Markdown (and show the editor formatting toolbar).
  static const String kMarkdownEnabled = 'markdown_enabled';

  /// Whether the one-time first-run intro has been shown (mobile).
  static const String kSeenOnboarding = 'seen_onboarding';
}
