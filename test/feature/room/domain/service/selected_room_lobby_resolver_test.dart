import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/service/selected_room_lobby_resolver.dart';

void main() {
  late SharedPreferencesRoomRepository repository;
  late SelectedRoomLobbyResolver resolver;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    resolver = SelectedRoomLobbyResolver(repository);
  });

  test('returns only an active non-archived selected Room', () async {
    final saved = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Rider one',
    );
    await repository.select(saved.room.id);

    final resolved = await resolver.resolve();

    expect(resolved?.room.id, saved.room.id);
    expect(resolved?.membership.localMemberId, saved.membership.localMemberId);
  });

  test('selection alone never creates a Room or transport state', () async {
    expect(await resolver.resolve(), isNull);
    expect(await repository.list(includeArchived: true), isEmpty);
  });

  test('archived selected Room fails closed', () async {
    final saved = await repository.create(
      name: 'Archived ride',
      localDisplayName: 'Rider one',
    );
    await repository.select(saved.room.id);
    await repository.setArchived(saved.room.id, true);

    expect(await resolver.resolve(), isNull);
  });

  test('left selected Room fails closed', () async {
    final saved = await repository.create(
      name: 'Old ride',
      localDisplayName: 'Rider one',
    );
    await repository.select(saved.room.id);
    await repository.leave(saved.room.id);

    expect(await resolver.resolve(), isNull);
  });
}
