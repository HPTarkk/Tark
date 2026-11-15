import 'dart:async';

import '../network/service_api.dart';
import '../profile/avatar_catalog.dart';
import '../settings/settings_repository.dart';
import '../utils/logger.dart';
import 'account_models.dart';
import 'account_session.dart';
import 'account_store.dart';

/// Keeps the account's name and avatar in step with the local profile.
///
/// The local profile (SettingsRepository) stays the source of truth: it is
/// what the radio uses, and it works with no account and no network. While
/// signed in, every local change is pushed with PUT /profile; a change made
/// offline is remembered and pushed at the next launch.
///
/// Signing in is the one moment the account wins: a name and avatar the
/// account already has are pulled down onto this phone, and never
/// overwritten by whatever this phone used before. Only what the account
/// lacks — a brand-new account has no avatar yet — goes up from the phone.
class ProfileSync {
  ProfileSync({
    required this._session,
    required this._store,
    required this._settings,
  });

  final AccountSession _session;
  final AccountStore _store;
  final SettingsRepository _settings;
  final _subs = <StreamSubscription<Object?>>[];
  Future<void>? _pushing;
  bool _again = false;

  /// True while a sign-in writes the account's profile onto this phone.
  /// Those writes are not the person's own changes and must not be pushed
  /// half-applied (the account's name with the phone's old avatar).
  bool _adopting = false;

  /// Starts listening. Also pushes a change left over from last time.
  Future<void> start() async {
    if (!_session.available) return;
    _subs
      ..add(_settings.myNameChanges.listen((_) => _localChanged()))
      ..add(_settings.myAvatarIdChanges.listen((_) => _localChanged()))
      ..add(_session.signedIn.listen((p) => unawaited(_onSignedIn(p))));
    if (_session.isSignedIn && await _store.isProfileDirty()) {
      unawaited(push());
    }
  }

  void _localChanged() {
    if (!_session.isSignedIn || _adopting) return;
    unawaited(push());
  }

  Future<void> _onSignedIn(AccountProfile remote) async {
    final remoteName = remote.name.trim();
    final remoteAvatar = remote.localAvatarId;
    _adopting = true;
    try {
      if (remoteName.isNotEmpty &&
          (await _settings.getMyName()).trim() != remoteName) {
        await _settings.setMyName(remoteName);
      }
      if (AvatarCatalog.isValidId(remoteAvatar) &&
          await _settings.getMyAvatarId() != remoteAvatar) {
        await _settings.setMyAvatarId(remoteAvatar!);
      }
    } finally {
      _adopting = false;
    }
    // Sends only what the account still lacks; a no-op when the phone now
    // matches the account.
    await push();
  }

  /// PUT /profile with the local name and avatar. Coalesces: a change made
  /// while a push is in flight is sent once that one ends.
  Future<void> push() {
    final running = _pushing;
    if (running != null) {
      _again = true;
      return running;
    }
    final future = _pushLoop();
    _pushing = future;
    return future.whenComplete(() => _pushing = null);
  }

  Future<void> _pushLoop() async {
    do {
      _again = false;
      await _pushOnce();
    } while (_again);
  }

  Future<void> _pushOnce() async {
    if (!_session.isSignedIn) return;
    final name = (await _settings.getMyName()).trim();
    if (name.isEmpty) return;
    final avatar = await _settings.getMyAvatarId();
    final current = _session.current;
    final avatarString = avatar?.toString();
    if (current != null &&
        current.name == name &&
        current.avatarId == avatarString) {
      await _store.setProfileDirty(false);
      return;
    }
    final response = await _session.api.send(
      ApiRequest(
        ApiMethod.put,
        '/profile',
        body: {'name': name, 'avatarId': avatarString},
      ),
    );
    switch (response) {
      case ApiOk(:final body):
        final profile = AccountProfile.fromJson(body);
        if (profile != null) await _session.updateProfile(profile);
        await _store.setProfileDirty(false);
      case ApiSignedOut():
        break;
      case ApiProblem(statusCode: 400):
        // The server refuses this name (a character it cannot show). The
        // local name stays; trying again with the same value cannot help.
        Logger.log('Account: profile refused (${response.code})');
        await _store.setProfileDirty(false);
      case ApiProblem() || ApiTransportFailure():
        Logger.log('Account: profile not synced yet ($response)');
        await _store.setProfileDirty(true);
    }
  }

  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
