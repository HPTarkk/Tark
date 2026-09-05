import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stranded Room recovery never derives transport role from Room rights', () {
    final source = File(
      'lib/feature/room/presentation/widget/in_room_people_action.dart',
    ).readAsStringSync();

    final connectStart = source.indexOf('  void _connect() {');
    final connectEnd = source.indexOf('\n  Future<void> _open()', connectStart);

    expect(connectStart, greaterThanOrEqualTo(0));
    expect(connectEnd, greaterThan(connectStart));

    final connect = source.substring(connectStart, connectEnd);

    // #186 field evidence showed two authorised Room members could both be
    // sent down `intent=create`. Durable invite authority is not a transport
    // election signal; recovery must follow the temporary role owned by the
    // live attachment instead.
    expect(connect, contains('_transferRepository?.sessionRole'));
    expect(connect, contains('role == SessionRole.host'));
    expect(connect, contains('ChannelIntent.create'));
    expect(connect, contains('ChannelIntent.join'));
    expect(connect, isNot(contains('canManageInvites')));
  });
}
