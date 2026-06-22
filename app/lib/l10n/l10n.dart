import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// Shorthand for the generated [AppLocalizations] of the current context, so
/// widgets can read translated strings as `context.l10n.someKey`.
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}

/// The locales this app ships translations for. The first is the fallback.
const List<Locale> kSupportedLocales = [Locale('en'), Locale('cs')];
