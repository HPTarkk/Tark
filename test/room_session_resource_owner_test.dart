import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/service/room_session_resource_owner.dart';

void main() {
  test('attachment replacement disposes only the replaced generation', () async {
    final owner = RoomSessionResourceOwner();
    final disposed = <String>[];

    owner.ownRoomResource('audio-engine', () => disposed.add('audio-engine'));
    owner.ownAttachmentResource(1, 'rx-socket', () => disposed.add('rx-1'));
    owner.ownAttachmentResource(1, 'tx-socket', () => disposed.add('tx-1'));
    owner.ownAttachmentResource(2, 'rx-socket', () => disposed.add('rx-2'));

    await owner.disposeAttachment(1);

    expect(disposed, ['tx-1', 'rx-1']);
    expect(owner.roomResourceCount, 1);
    expect(owner.attachmentResourceCount(1), 0);
    expect(owner.attachmentResourceCount(2), 1);
  });

  test('repeated disposal of one attachment generation is a no-op', () async {
    final owner = RoomSessionResourceOwner();
    var calls = 0;
    owner.ownAttachmentResource(7, 'subscription', () => calls++);

    await owner.disposeAttachment(7);
    await owner.disposeAttachment(7);
    await owner.disposeAttachment(7);

    expect(calls, 1);
  });

  test('explicit leave disposes attachments before room resources exactly once', () async {
    final owner = RoomSessionResourceOwner();
    final disposed = <String>[];

    owner.ownRoomResource('audio-engine', () => disposed.add('audio'));
    owner.ownRoomResource('room-subscription', () => disposed.add('room-sub'));
    owner.ownAttachmentResource(1, 'socket', () => disposed.add('attachment-1'));
    owner.ownAttachmentResource(2, 'timer', () => disposed.add('attachment-2'));

    await owner.disposeAll();
    await owner.disposeAll();

    expect(
      disposed,
      ['attachment-2', 'attachment-1', 'room-sub', 'audio'],
    );
    expect(owner.isDisposed, isTrue);
  });

  test('a disposed owner rejects new resources', () async {
    final owner = RoomSessionResourceOwner();
    await owner.disposeAll();

    expect(
      () => owner.ownRoomResource('late', () {}),
      throwsStateError,
    );
    expect(
      () => owner.ownAttachmentResource(1, 'late', () {}),
      throwsStateError,
    );
  });

  test('duplicate ownership keys fail instead of leaking the previous resource', () {
    final owner = RoomSessionResourceOwner();
    owner.ownRoomResource('audio', () {});
    owner.ownAttachmentResource(3, 'socket', () {});

    expect(() => owner.ownRoomResource('audio', () {}), throwsStateError);
    expect(
      () => owner.ownAttachmentResource(3, 'socket', () {}),
      throwsStateError,
    );
  });
}
