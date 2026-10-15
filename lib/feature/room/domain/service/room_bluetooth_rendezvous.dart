import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../entity/room.dart';
import '../entity/room_invite_link.dart';

/// How two phones of the same Room find each other over Bluetooth with no
/// code to scan and no network to ask over.
///
/// Both phones already know the Room and each other, so both can work out
/// the same two things on their own: which of them listens (the lower member
/// id) and what it listens for (a token both derive from the Room). The other
/// phone searches for exactly that token. Nothing here is proof of anything:
/// the token only picks the right phone out of the ones nearby, and the
/// signed Room proofs that follow over the link are what let it in.
///
/// The token turns over each UTC day, so a phone does not advertise the same
/// thing for the life of the Room.
abstract final class RoomBluetoothRendezvous {
  /// The member who listens; the other searches.
  static RoomMemberId listenerOf(RoomMemberId a, RoomMemberId b) =>
      a.value.compareTo(b.value) <= 0 ? a : b;

  /// The link [listener] advertises for [room] on [now]'s UTC day.
  static Future<BluetoothInviteLink> linkFor({
    required RoomId room,
    required RoomMemberId listener,
    DateTime? now,
  }) async {
    final day = (now ?? DateTime.now()).toUtc();
    final digest = await Sha256().hash(
      utf8.encode(
        'tark-room-bluetooth-rendezvous-v1\n'
        '${room.value}\n${listener.value}\n'
        '${day.year}-${day.month}-${day.day}',
      ),
    );
    final token = digest.bytes
        .take(16)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return BluetoothInviteLink(token);
  }
}
