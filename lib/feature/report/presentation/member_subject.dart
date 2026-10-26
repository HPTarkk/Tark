import 'package:flutter/widgets.dart';

import '../domain/listener_mutes.dart';

/// Someone in the room, as the member card and the report story see them.
///
/// The two rosters know people differently (a durable Room member, or only a
/// live sender in a quick channel), so this carries whichever keys exist and
/// decides once how muting them works.
@immutable
class MemberSubject {
  const MemberSubject({
    required this.name,
    required this.seed,
    required this.avatar,
    this.avatarId,
    this.roomId,
    this.roomName,
    this.memberId,
    this.senderId,
  });

  final String name;

  /// What their tint is derived from, so the story's character wears the
  /// same colour as their face in the roster.
  final String seed;

  /// Their face as the roster draws it, at whatever size the caller asks.
  final Widget Function(double size) avatar;

  /// Their picked avatar, so the report story can cast them as themselves.
  /// Null, or an id this build has no picture for, plays them as their
  /// initial on their colour.
  final int? avatarId;

  final String? roomId;
  final String? roomName;
  final String? memberId;

  /// Their live sender id, when they are on the air right now.
  final String? senderId;

  bool get _durable => roomId != null && memberId != null;

  /// Whether anything can be muted at all: a Room member always, a quick
  /// channel peer only while their sender is known.
  bool get canMute => _durable || senderId != null;

  bool isMuted(ListenerMutes mutes) {
    if (_durable) return mutes.isMemberMuted(roomId!, memberId!);
    final sender = senderId;
    return sender != null && mutes.isSenderMuted(sender);
  }

  Future<void> setMuted(ListenerMutes mutes, bool muted) async {
    if (_durable) {
      await mutes.setMemberMuted(roomId!, memberId!, muted, senderId: senderId);
      return;
    }
    final sender = senderId;
    if (sender != null) mutes.setSenderMuted(sender, muted);
  }
}
