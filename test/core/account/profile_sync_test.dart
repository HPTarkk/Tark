import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/account/profile_sync.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/core/profile/local_profile.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';

import 'account_fakes.dart';

void main() {
  late AccountHarness h;
  late SettingsRepositoryImpl settings;
  late ProfileSync sync;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SettingsKeys.userName: 'Falcon',
      SettingsKeys.avatarId: 8,
    });
    settings = SettingsRepositoryImpl(await SharedPreferences.getInstance());
    h = AccountHarness();
    sync = ProfileSync(session: h.session, store: h.store, settings: settings);
  });

  tearDown(() async {
    await sync.dispose();
    LocalProfile.avatarId = null;
  });

  Map<String, dynamic> echo(ApiRequest r) => {
    ...profileJson(),
    'name': r.body!['name'],
    'avatarId': r.body!['avatarId'],
  };

  test('signing in to an existing account pulls its name and avatar down, '
      'and never overwrites them', () async {
    h.client.handler = (r) async => ApiOk(200, echo(r));
    await sync.start();
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Pedi', avatarId: '3'),
      ),
    );
    await settle();
    await settle();

    expect(await settings.getMyName(), 'Pedi');
    expect(await settings.getMyAvatarId(), 3);
    expect(h.client.to('/profile'), isEmpty);
    expect(h.session.current!.name, 'Pedi');
    expect(h.session.current!.avatarId, '3');
  });

  test('a brand-new account without an avatar takes the phone\'s', () async {
    h.client.handler = (r) async => ApiOk(200, echo(r));
    await sync.start();
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Falcon', avatarId: null),
      ),
    );
    await settle();
    await settle();

    final put = h.client.to('/profile').single;
    expect(put.method, ApiMethod.put);
    expect(put.body, {'name': 'Falcon', 'avatarId': '8'});
    expect(await settings.getMyAvatarId(), 8);
  });

  test('an account with a name but no avatar keeps its name and gets the '
      'phone\'s avatar', () async {
    h.client.handler = (r) async => ApiOk(200, echo(r));
    await sync.start();
    await h.signIn(
      session: sessionJson(profile: profileJson(name: 'Pedi', avatarId: null)),
    );
    await settle();
    await settle();

    expect(await settings.getMyName(), 'Pedi');
    expect(h.client.to('/profile').single.body, {
      'name': 'Pedi',
      'avatarId': '8',
    });
  });

  test('a change after sign-in still goes up', () async {
    h.client.handler = (r) async => ApiOk(200, echo(r));
    await sync.start();
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Pedi', avatarId: '3'),
      ),
    );
    await settle();
    await settle();
    await settings.setMyName('Hawk');
    await settle();
    await settle();

    expect(h.client.to('/profile').single.body, {
      'name': 'Hawk',
      'avatarId': '3',
    });
  });

  test('a local change while signed in is pushed', () async {
    h.client.handler = (r) async => ApiOk(200, echo(r));
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Falcon', avatarId: '8'),
      ),
    );
    await sync.start();

    await settings.setMyAvatarId(5);
    await settle();
    await settle();

    expect(h.client.to('/profile').single.body, {
      'name': 'Falcon',
      'avatarId': '5',
    });
  });

  test('nothing is sent while signed out', () async {
    await sync.start();
    await settings.setMyName('Other');
    await settle();
    expect(h.client.requests, isEmpty);
  });

  test('an offline change is remembered and pushed at next start', () async {
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Falcon', avatarId: '8'),
      ),
    );
    h.client.handler = (_) async =>
        const ApiTransportFailure(NetworkUnreachable('offline'));
    await sync.start();
    await settings.setMyName('Hawk');
    await settle();
    await settle();
    expect(await h.store.isProfileDirty(), isTrue);

    await sync.dispose();
    h.client.handler = (r) async => ApiOk(200, echo(r));
    sync = ProfileSync(session: h.session, store: h.store, settings: settings);
    await sync.start();
    await settle();
    await settle();

    expect(h.client.to('/profile').last.body!['name'], 'Hawk');
    expect(await h.store.isProfileDirty(), isFalse);
  });

  test('an edit is pending before a slow upload answers and retries', () async {
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Falcon', avatarId: '8'),
      ),
    );
    final response = Completer<ApiResponse>();
    final uploadStarted = Completer<void>();
    h.client.handler = (_) {
      uploadStarted.complete();
      return response.future;
    };
    await sync.start();

    await settings.setMyName('Hawk');
    await uploadStarted.future;
    expect(await settings.getMyName(), 'Hawk');
    expect(await h.store.isProfileDirty(), isTrue);

    response.complete(const ApiTransportFailure(NetworkUnreachable('offline')));
    await settle();
    expect(h.session.isSignedIn, isTrue);
    expect(await h.store.isProfileDirty(), isTrue);

    h.client.handler = (r) async => ApiOk(200, echo(r));
    await sync.retryPending();
    await settle();
    expect(h.client.to('/profile').last.body!['name'], 'Hawk');
    expect(await h.store.isProfileDirty(), isFalse);
  });

  test('a phone with no name yet takes the account name', () async {
    await settings.setMyName('');
    await sync.start();
    await h.signIn(
      session: sessionJson(
        profile: profileJson(name: 'Pedi', avatarId: '3'),
      ),
    );
    await settle();
    await settle();
    expect(await settings.getMyName(), 'Pedi');
  });
}
