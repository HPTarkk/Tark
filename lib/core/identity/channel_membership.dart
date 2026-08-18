import 'dart:async';

import 'package:injectable/injectable.dart';

import 'channel_id.dart';

/// The channel this device is currently in, if any.
///
/// The mutable half of [ChannelId], shaped after [SessionEpoch]: one process-wide
/// holder that the codec reads at encode time rather than capturing, because
/// the codec outlives any one session and joining a channel has to change what
/// goes on the wire without rebuilding it.
///
/// **Session-scoped, never persisted.** Which channel you were in last time says
/// nothing about this time, and a remembered channel is worse than no channel: it
/// would have a phone open on a code its group is no longer using and hear
/// nobody, with the screen reporting a perfectly healthy link. The same
/// reasoning already keeps [SessionRoleStore] out of preferences.
@lazySingleton
class ChannelMembership {
  ChannelMembership();

  ChannelId _current = ChannelId.open;
  final _changes = StreamController<ChannelId>.broadcast();

  /// The channel stamped on everything currently going out.
  ChannelId get current => _current;

  /// Emits on every change, so a screen showing the code does not have to poll
  /// for a channel adopted by the scanner on another page.
  Stream<ChannelId> get changes => _changes.stream;

  /// Starts a fresh channel — what "create a channel" means literally.
  ChannelId create() {
    final id = ChannelId.generate();
    _set(id);
    return id;
  }

  /// Creates one only if we are not already in a channel.
  ///
  /// Both ends of the create path call this — the landing page, which is where
  /// "start a channel" is tapped, and the hotspot host flow, which can also be
  /// reached straight from Settings without passing the landing page. Whichever
  /// runs first wins, so arriving by the long route does not renumber a channel
  /// whose code may already be on the other phone's screen.
  ChannelId createIfNone() => current.isOpen ? create() : current;

  /// Adopts a channel handed over by a scanned code or one typed in.
  void join(ChannelId id) => _set(id);

  /// Back to hearing everyone. Called when a session ends, so the next one
  /// starts from the honest default rather than from whoever we last talked
  /// to.
  void leave() => _set(ChannelId.open);

  void _set(ChannelId id) {
    if (id.value == _current.value) return;
    _current = id;
    if (!_changes.isClosed) _changes.add(id);
  }
}
