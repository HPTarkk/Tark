import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/profile/avatar_catalog.dart';
import 'package:tark/core/profile/profile_defaults.dart';
import 'package:tark/core/settings/settings_repository.dart';

class _Settings implements SettingsRepository {
  _Settings({this.avatarId});

  int? avatarId;
  final String name = 'Pedi';
  int writes = 0;

  @override
  Future<int?> getMyAvatarId() async => avatarId;

  @override
  Future<void> setMyAvatarId(int value) async {
    writes++;
    avatarId = value;
  }

  @override
  Future<String> getMyName() async => name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('someone who set up before avatars gets the Tarkk mascot', () async {
    final settings = _Settings();
    await ProfileDefaults.ensureAvatar(settings, setupDone: true);
    expect(settings.avatarId, AvatarCatalog.defaultId);
  });

  test('a picked avatar is never replaced', () async {
    final settings = _Settings(avatarId: 11);
    await ProfileDefaults.ensureAvatar(settings, setupDone: true);
    expect(settings.avatarId, 11);
    expect(settings.writes, 0);
  });

  test('a first run is left to pick in setup', () async {
    final settings = _Settings();
    await ProfileDefaults.ensureAvatar(settings, setupDone: false);
    expect(settings.avatarId, isNull);
  });
}
