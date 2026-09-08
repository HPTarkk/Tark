import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Room Start keeps the durable lobby visible while connecting', () {
    final source = File(
      'lib/app/router/room_bound_walkie_entry.dart',
    ).readAsStringSync();

    expect(source, contains('connectionPhase: RoomConnectionUiPhase.connecting'));
    expect(source, contains('final room = _attemptRoom;'));
    expect(source, contains('SelectedRoomLobby('));
  });

  test('listed readiness failures return typed recoverable lobby state', () {
    final source = File(
      'lib/app/router/room_bound_walkie_entry.dart',
    ).readAsStringSync();

    for (final failure in [
      'transportBindTimeout',
      'peerProofMissing',
      'staleAttempt',
      'transportPlanMismatch',
      'coordinatorRejected',
      'transportSetup',
    ]) {
      expect(source, contains('_EntryFailure.$failure'));
    }
    expect(source, contains('failureMessage: _failureMessage(context, state.failure)'));
    expect(source, contains('onRetry: state.failure == null ? null : () => _startRide(room)'));
  });

  test('legacy audio requires an explicit null durable Room selection', () {
    final source = File(
      'lib/app/router/room_bound_walkie_entry.dart',
    ).readAsStringSync();

    expect(source, contains('final selectedId = await rooms.selectedRoomId();'));
    expect(source, contains('if (selectedId != null)'));
    expect(
      source,
      contains('return const _EntryState.recoverable(_EntryFailure.selectionReadFailed);'),
    );
    expect(source, contains('return const _EntryState.live();'));
  });

  test('normal lobby recovery copy has no transport credential instructions', () {
    final lobby = File(
      'lib/feature/room/presentation/widget/selected_room_lobby.dart',
    ).readAsStringSync();

    expect(lobby, contains("context.getString.retry"));
    expect(lobby, contains("key: const Key('selected-room-start-failure')"));
    expect(lobby, isNot(contains('SSID')));
    expect(lobby, isNot(contains('IP address')));
  });
}
