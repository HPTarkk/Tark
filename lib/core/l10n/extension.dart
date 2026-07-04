import 'package:flutter/widgets.dart';
import 'package:tark/core/l10n/app_localizations.dart';

extension AppLocalizationsExt on BuildContext {
  AppLocalizations get getString => AppLocalizations.of(this)!;
}
