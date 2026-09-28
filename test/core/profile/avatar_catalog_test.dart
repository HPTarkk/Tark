import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/profile/avatar_catalog.dart';

void main() {
  test('every id is unique and in range', () {
    final ids = AvatarCatalog.all.map((a) => a.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.every(AvatarCatalog.isValidId), isTrue);
  });

  test('the shipped ids never change', () {
    // Ids are stored and sent to other phones; renumbering one would show
    // everyone who picked it as someone else.
    expect(AvatarCatalog.byId(1)!.asset, 'assets/avatars/01-man.webp');
    expect(AvatarCatalog.byId(12)!.asset, 'assets/avatars/12-alien.webp');
    expect(AvatarCatalog.byId(13)!.asset, 'assets/avatars/13-tarkk.webp');
    expect(AvatarCatalog.byId(19)!.asset, 'assets/avatars/19-gamer.webp');
    expect(AvatarCatalog.all, hasLength(19));
  });

  test('the Tarkk mascot is the default and leads the picker', () {
    expect(AvatarCatalog.defaultId, 13);
    expect(AvatarCatalog.all.first.id, AvatarCatalog.defaultId);
  });

  test('every picture is bundled', () {
    for (final avatar in AvatarCatalog.all) {
      expect(File(avatar.asset).existsSync(), isTrue, reason: avatar.asset);
    }
  });

  test('unknown and malformed ids', () {
    expect(AvatarCatalog.byId(null), isNull);
    expect(AvatarCatalog.byId(200), isNull);
    expect(AvatarCatalog.isValidId(200), isTrue, reason: 'a newer avatar');
    expect(AvatarCatalog.isValidId(0), isFalse);
    expect(AvatarCatalog.isValidId(256), isFalse);
    expect(AvatarCatalog.isValidId(-1), isFalse);
  });
}
