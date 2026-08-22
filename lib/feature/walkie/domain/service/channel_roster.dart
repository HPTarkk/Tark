import '../../../transfer/api/transfer_api.dart';
import '../entity/channel_user.dart';

/// What a roster operation observed, so the cubit can map it to the matching
/// audio cue without the roster knowing about SFX.
enum RosterChange {
  none,
  peerJoined,
  peerStartedTalking,
  peerLeft,

  /// A peer announced its own departure (see [ChannelRoster.announceLeave]),
  /// distinct from [peerLeft]'s timeout-based removal so the UI can react
  /// instantly and visibly rather than only after the peer has aged past
  /// [ChannelRoster.staleAfterSeconds] in silence.
  peerAnnouncedLeave,
}

class RosterUpdate {
  const RosterUpdate(this.users, this.change, {this.subject});

  final List<ChannelUser> users;
  final RosterChange change;

  /// Who triggered the change, when there is exactly one — null for
  /// [cleanup]'s bulk removals, where more than one user can go stale in the
  /// same tick.
  final ChannelUser? subject;
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
      // Only presence announces a role; audio packets say nothing about it.
      // Without this, every frame of someone talking would wipe the role they
      // announced two seconds ago and their badge would flicker.
      updated[idx] = user.role == SessionRole.unknown
          ? user.copyWith(role: updated[idx].role)
          : user;
      return RosterUpdate(
        updated,
        startedTalking ? RosterChange.peerStartedTalking : RosterChange.none,
      );
    }
    updated.add(user);
    return RosterUpdate(updated, RosterChange.peerJoined);
  }

  /// Removes [id] immediately because it announced its own departure,
  /// instead of waiting for it to age past [staleAfterSeconds] in silence.
  /// [RosterChange.none] if [id] was not present — a stray or duplicate
  /// leave announcement, which is not a change worth reacting to.
  RosterUpdate announceLeave(List<ChannelUser> users, String id) {
    final idx = users.indexWhere((u) => u.id == id);
    if (idx < 0) return RosterUpdate(users, RosterChange.none);
    final updated = List<ChannelUser>.of(users)..removeAt(idx);
    return RosterUpdate(
      updated,
      RosterChange.peerAnnouncedLeave,
      subject: users[idx],
    );
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
