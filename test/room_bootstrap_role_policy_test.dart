import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Room bootstrap side is independent from invite-management rights', () {
    final entry = File(
      'lib/app/router/room_bound_walkie_entry.dart',
    ).readAsStringSync();
    final start = entry.indexOf('  ChannelIntent _bootstrapIntent(');
    final end = entry.indexOf('\n  /// Sends a Room with no link', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final bootstrap = entry.substring(start, end);
    expect(bootstrap, contains('_transfer?.sessionRole'));
    expect(bootstrap, contains('SessionRole.host'));
    expect(bootstrap, contains('SessionRole.joiner'));
    expect(bootstrap, contains('joinedAt.compareTo'));
    expect(bootstrap, isNot(contains('canManageInvites')));
  });

  test('create and one-scan join stamp opposite session-scoped role hints', () {
    final cubit = File(
      'lib/feature/room/presentation/manager/room_list_cubit.dart',
    ).readAsStringSync();

    final createStart = cubit.indexOf('  Future<SavedRoom?> createRoom(');
    final createEnd = cubit.indexOf(
      '\n  Future<RoomInviteJoinAttemptStatus> joinByInvite(',
      createStart,
    );
    final directStart = cubit.indexOf('  Future<bool> joinDirect(');
    final directEnd = cubit.indexOf('\n  void cancelInviteJoin()', directStart);

    expect(createStart, greaterThanOrEqualTo(0));
    expect(createEnd, greaterThan(createStart));
    expect(directStart, greaterThanOrEqualTo(0));
    expect(directEnd, greaterThan(directStart));

    expect(
      cubit.substring(createStart, createEnd),
      contains('setRole(SessionRole.host)'),
    );
    expect(
      cubit.substring(directStart, directEnd),
      contains('setRole(SessionRole.joiner)'),
    );
  });
}
