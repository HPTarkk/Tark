import '../settings/settings_repository.dart';
import 'avatar_catalog.dart';

/// Fills in profile fields a person has not chosen yet.
abstract final class ProfileDefaults {
  /// Gives someone who has finished (or skipped) setup a default avatar when
  /// they have none — everyone who set up before avatars existed, and anyone
  /// who skips the setup flow. It is stored, so it stays put and other phones
  /// see the same face, and it can be changed on the Profile page.
  ///
  /// A first run that has not finished setup is left alone: the avatar step
  /// is where that person picks one.
  static Future<void> ensureAvatar(
    SettingsRepository settings, {
    required bool setupDone,
  }) async {
    // Read even when setup is not done: the read is also what seeds
    // [LocalProfile] for the wire.
    final current = await settings.getMyAvatarId();
    if (!setupDone || current != null) return;
    final name = await settings.getMyName();
    await settings.setMyAvatarId(AvatarCatalog.defaultFor(name));
  }
}
