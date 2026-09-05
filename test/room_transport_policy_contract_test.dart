import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('room-first UX hides transport mechanics from primary lobby', () {
    final source = File(
      'lib/feature/room/presentation/widget/selected_room_lobby.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('lobby_unlinked_heading')));
    expect(source, isNot(contains('lobby_different_network')));
    expect(source, isNot(contains('selected-room-shared-network-callout')));
    expect(source, isNot(contains('selected-room-different-network')));
  });

  test('pending invite seats do not decide whether the lobby is alone', () {
    final source = File(
      'lib/feature/room/presentation/widget/selected_room_lobby.dart',
    ).readAsStringSync();

    expect(source, contains('final alone = members.length <= 1;'));
    expect(source, isNot(contains('members.length <= 1 && held.isEmpty')));
  });

  test('transport planner keeps proven shared LAN ahead of hotspot', () {
    final source = File(
      'lib/feature/room/domain/service/room_transport_planner.dart',
    ).readAsStringSync();

    final lan = source.indexOf('if (environment.sharedLanUsable)');
    final hotspot = source.indexOf('final hotspotCandidates');
    expect(lan, greaterThanOrEqualTo(0));
    expect(hotspot, greaterThan(lan));
    expect(source, contains('peer-proven'));
  });
}
