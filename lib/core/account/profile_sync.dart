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
/// offline is remembered and pushed at the next launch or sign-in. Signing
/// in pushes the local profile too, so the phone the person is holding
/// wins — except when this phone has no name of its own yet, which then
/// takes the account's.
class ProfileSync {
  ProfileSync({
    required AccountSession session,
    required AccountStore store,
    required SettingsRepository settings,
  }) : _session = session,
       _store = store,
       _settings = settings;

  final AccountSession _session;
  final AccountStore _store;
  final SettingsRepository _settings;
  final _subs = <StreamSubscription<Object?>>[];
  Future<void>? _pushing;
  bool _again = false;

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
    if (!_session.isSignedIn) return;
    unawaited(push());
  }

  Future<void> _onSignedIn(AccountProfile remote) async {
    final localName = (await _settings.getMyName()).trim();
    if (localName.isEmpty && remote.name.trim().isNotEmpty) {
      await _settings.setMyName(remote.name.trim());
      final avatar = remote.localAvatarId;
      if (await _settings.getMyAvatarId() == null &&
          AvatarCatalog.isValidId(avatar)) {
        await _settings.setMyAvatarId(avatar!);
      }
      return;
    }
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
