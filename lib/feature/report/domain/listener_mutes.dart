import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who this phone has chosen not to hear.
///
/// A mute is the listener's own business: nothing goes on the wire, the muted
/// person keeps talking to everybody else, and they are never told. It exists
/// so that someone who reports a rider (or simply cannot stand them) is
/// protected the moment they ask, instead of after anybody reviews anything.
///
/// Two kinds of key, because the two rosters identify people differently:
///
/// * **Room members** are durable (`RoomId` + `RoomMemberId`), so their mute
///   is persisted and survives restarts and later rides.
/// * **Live senders** are what audio packets actually carry. A sender id is
///   generated per process (see `DeviceIdentity`), so it is only ever a
///   session key: the Room roster maps a muted member onto whichever sender id
///   their verified route proof arrives with today ([bindSender]), and a quick
///   channel without a Room mutes the sender directly, for this session only.
///
/// A plain singleton rather than an injected service: the channel cubit asks
/// [isSenderMuted] once per received packet, and threading a new dependency
/// through its generated constructor would buy nothing over one shared set.
class ListenerMutes extends ChangeNotifier {
  ListenerMutes({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  /// The one the app uses.
  static final ListenerMutes instance = ListenerMutes();

  static const _storeKey = 'listener_mutes.members.v1';

  final Future<SharedPreferences> Function() _prefs;
  final Set<String> _members = {};
  final Set<String> _senders = {};

  /// Sender ids that are muted *because* a muted member was seen on them, so
  /// unmuting the member can release exactly those.
  final Map<String, String> _senderMember = {};

  Future<void>? _loading;

  static String memberKey(String roomId, String memberId) =>
      '$roomId/$memberId';

  /// Reads the persisted member mutes once. Safe to call from anywhere and as
  /// often as convenient; a failed read leaves the set empty (nobody muted),
  /// which is the only safe failure for a feature that silences people.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final stored = (await _prefs()).getStringList(_storeKey);
      if (stored == null || stored.isEmpty) return;
      final before = _members.length;
      _members.addAll(stored);
      if (_members.length != before) notifyListeners();
    } catch (_) {
      // No storage (tests, a broken plugin): mutes stay in memory only.
    }
  }

  /// Hot path: called for every received audio packet.
  bool isSenderMuted(String senderId) => _senders.contains(senderId);

  bool isMemberMuted(String roomId, String memberId) =>
      _members.contains(memberKey(roomId, memberId));

  /// Mutes or unmutes a durable Room member, and [senderId] with them when
  /// their live sender is already known.
  Future<void> setMemberMuted(
    String roomId,
    String memberId,
    bool muted, {
    String? senderId,
  }) async {
    final key = memberKey(roomId, memberId);
    final changed = muted ? _members.add(key) : _members.remove(key);
    if (muted && senderId != null) {
      _senders.add(senderId);
      _senderMember[senderId] = key;
    }
    if (!muted) {
      final released = [
        for (final entry in _senderMember.entries)
          if (entry.value == key) entry.key,
      ];
      for (final sender in released) {
        _senderMember.remove(sender);
        _senders.remove(sender);
      }
      if (senderId != null) _senders.remove(senderId);
    }
    notifyListeners();
    if (!changed) return;
    try {
      await (await _prefs()).setStringList(
        _storeKey,
        _members.toList(growable: false),
      );
    } catch (_) {
      // Kept in memory for this session; nothing else to do.
    }
  }

  /// Session-only mute for someone known only by their live sender id (a
  /// quick channel with no Room behind it).
  void setSenderMuted(String senderId, bool muted) {
    final changed = muted ? _senders.add(senderId) : _senders.remove(senderId);
    if (!muted) _senderMember.remove(senderId);
    if (changed) notifyListeners();
  }

  /// Tells the registry which live sender a Room member is speaking as right
  /// now. Idempotent and cheap, so a roster row can call it on every build.
  void bindSender(String roomId, String memberId, String senderId) {
    final key = memberKey(roomId, memberId);
    if (!_members.contains(key)) return;
    if (_senderMember[senderId] == key && _senders.contains(senderId)) return;
    _senderMember[senderId] = key;
    _senders.add(senderId);
    // Listeners only care about members, which did not change; the cubit
    // reads [isSenderMuted] directly. No notification, so this is safe to
    // call during build.
  }

  @visibleForTesting
  void resetForTest() {
    _members.clear();
    _senders.clear();
    _senderMember.clear();
    _loading = null;
  }
}
