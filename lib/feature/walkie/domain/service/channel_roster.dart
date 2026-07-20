import '../entity/channel_user.dart';

/// What a roster operation observed, so the cubit can map it to the matching
/// audio cue without the roster knowing about SFX.
enum RosterChange { none, peerJoined, peerStartedTalking, peerLeft }

class RosterUpdate {
  const RosterUpdate(this.users, this.change);

  final List<ChannelUser> users;
  final RosterChange change;
}

/// Pure bookkeeping over the channel's user list — who's present, who's
/// talking, who went stale. No timers, no side effects: callers own the
/// clock and react to the returned [RosterChange].
class ChannelRoster {
  const ChannelRoster({
    this.staleAfterSeconds = 8,
    this.talkTimeoutSeconds = 3,
  });

  /// A user unseen for this long is dropped from the roster.
  final int staleAfterSeconds;

  /// A user still present but silent for this long is marked not-talking
  /// (their transport may only send presence every couple of seconds).
  final int talkTimeoutSeconds;

  /// Inserts or refreshes [user], reporting a join or a talk onset.
  RosterUpdate upsert(List<ChannelUser> users, ChannelUser user) {
    final updated = List<ChannelUser>.of(users);
    final idx = updated.indexWhere((u) => u.id == user.id);
    if (idx >= 0) {
      final startedTalking = !updated[idx].isTalking && user.isTalking;
      updated[idx] = user;
      return RosterUpdate(
        updated,
        startedTalking ? RosterChange.peerStartedTalking : RosterChange.none,
      );
    }
    updated.add(user);
    return RosterUpdate(updated, RosterChange.peerJoined);
  }

  /// Drops stale users and un-flags silent talkers, reporting a leave when
  /// anyone was removed.
  RosterUpdate cleanup(List<ChannelUser> users, DateTime now) {
    final updated = users
        .where((u) => now.difference(u.lastSeen).inSeconds < staleAfterSeconds)
        .map((u) {
          if (now.difference(u.lastSeen).inSeconds > talkTimeoutSeconds &&
              u.isTalking) {
            return u.copyWith(isTalking: false);
          }
          return u;
        })
        .toList();
    return RosterUpdate(
      updated,
      updated.length < users.length ? RosterChange.peerLeft : RosterChange.none,
    );
  }
}
