/// Every distinct UI sound cue the app can play. Kept flat (not per-feature)
/// since several features share the same semantic sound (e.g. "something
/// connected" is the same chime whether it's a WiFi peer, a Bluetooth pair,
/// or a browser guest).
enum SfxEvent {
  pttOpen,
  pttClose,
  rxStart,
  peerJoin,
  peerLeave,
  linkLost,
  linkRestored,
  error,
  toggle,
  channelJoin,
  channelLeave,
}

extension SfxEventAsset on SfxEvent {
  String get assetPath => switch (this) {
        SfxEvent.pttOpen => 'sfx/ptt_open.wav',
        SfxEvent.pttClose => 'sfx/ptt_close.wav',
        SfxEvent.rxStart => 'sfx/rx_start.wav',
        SfxEvent.peerJoin => 'sfx/peer_join.wav',
        SfxEvent.peerLeave => 'sfx/peer_leave.wav',
        SfxEvent.linkLost => 'sfx/link_lost.wav',
        SfxEvent.linkRestored => 'sfx/link_restored.wav',
        SfxEvent.error => 'sfx/error.wav',
        SfxEvent.toggle => 'sfx/toggle.wav',
        SfxEvent.channelJoin => 'sfx/channel_join.wav',
        SfxEvent.channelLeave => 'sfx/channel_leave.wav',
      };
}
