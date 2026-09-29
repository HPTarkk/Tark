import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/authenticated_api_client.dart';
import '../network/service_api.dart';
import '../utils/logger.dart';
import 'account_models.dart';
import 'account_store.dart';

/// Whether this phone is signed in, and as whom.
///
/// The signed-in state is shown from what is stored on the phone, so it
/// reads correctly offline; the server is only asked when something needs
/// it. The session ends when the person signs out, or when the server
/// refuses to refresh it (another phone signed out everywhere, the password
/// was reset, the account was deleted).
class AccountSession {
  AccountSession({
    required AuthenticatedApiClient api,
    required AccountStore store,
    required this.available,
  }) : _api = api,
       _store = store {
    _endedSub = _api.sessionEnded.listen((_) => unawaited(_endLocally()));
  }

  final AuthenticatedApiClient _api;
  final AccountStore _store;

  /// False on builds without sign-in (see AccountConfig.enabled). Screens
  /// hide every account affordance then.
  final bool available;

  final ValueNotifier<AccountProfile?> _profile = ValueNotifier(null);
  final _signedIn = StreamController<AccountProfile>.broadcast();
  final _signedOut = StreamController<void>.broadcast();
  StreamSubscription<void>? _endedSub;
  bool _loaded = false;

  /// The signed-in profile, or null when signed out.
  ValueListenable<AccountProfile?> get profile => _profile;

  AccountProfile? get current => _profile.value;
  bool get isSignedIn => _profile.value != null;

  /// Fires after every sign-in (a new session adopted).
  Stream<AccountProfile> get signedIn => _signedIn.stream;

  /// Fires after the session ends, whether asked for or not.
  Stream<void> get signedOut => _signedOut.stream;

  AuthenticatedApiClient get api => _api;

  /// Restores the signed-in state from storage. Cheap; no network.
  Future<void> load() async {
    if (_loaded || !available) return;
    _loaded = true;
    if (!await _api.hasSession()) {
      _profile.value = null;
      return;
    }
    final stored = await _store.readProfile();
    if (stored != null) {
      _profile.value = stored;
      return;
    }
    // Tokens without a profile (an interrupted write): ask once, in the
    // background — launch never waits on the network.
    unawaited(
      fetchProfile().then((fresh) {
        if (fresh == null) Logger.log('Account: profile not available yet');
      }),
    );
  }

  /// Adopts a `Session` answer from any sign-in endpoint. Returns the
  /// profile, or null when the answer was not a usable session.
  Future<AccountProfile?> adopt(Map<String, dynamic> session) async {
    final tokens = SessionTokens.fromJson(session);
    final profile = AccountProfile.fromJson(session['profile']);
    if (tokens == null || profile == null) {
      Logger.log('Account: sign-in answer was not a session');
      return null;
    }
    try {
      await _api.adopt(tokens);
    } catch (error) {
      Logger.log('Account: could not store tokens ($error)');
      return null;
    }
    await _saveProfile(profile);
    Logger.log('Account: signed in');
    if (!_signedIn.isClosed) _signedIn.add(profile);
    return profile;
  }

  /// GET /profile, keeping the stored copy current. Null when it could not
  /// be read (offline, signed out).
  Future<AccountProfile?> fetchProfile() async {
    final response = await _api.send(const ApiRequest.get('/profile'));
    if (response is ApiOk) {
      final profile = AccountProfile.fromJson(response.body);
      if (profile != null) await _saveProfile(profile);
      return profile;
    }
    return null;
  }

  /// Records a profile the server just returned.
  Future<void> updateProfile(AccountProfile profile) => _saveProfile(profile);

  /// Signs out here, and on the server when it can be reached.
  Future<void> signOut({bool everywhere = false}) async {
    final response = await _api.logout(everywhere: everywhere);
    if (response is! ApiOk && response is! ApiSignedOut) {
      Logger.log('Account: server sign-out not confirmed ($response)');
    }
    await _endLocally();
  }

  /// Ends the session on this phone after the server already did (account
  /// deleted).
  Future<void> endAfterServer() async {
    await _api.forget();
    await _endLocally();
  }

  Future<void> _saveProfile(AccountProfile profile) async {
    _profile.value = profile;
    try {
      await _store.writeProfile(profile);
    } catch (error) {
      Logger.log('Account: could not store profile ($error)');
    }
  }

  Future<void> _endLocally() async {
    final wasSignedIn = _profile.value != null;
    _profile.value = null;
    await _store.clearAccount();
    if (wasSignedIn) Logger.log('Account: signed out');
    if (!_signedOut.isClosed) _signedOut.add(null);
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _endedSub?.cancel();
    await _signedIn.close();
    await _signedOut.close();
    _profile.dispose();
  }
}
