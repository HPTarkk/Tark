/// What voice is actually routed through right now, as classified by
/// `VoiceAudioSession.getCurrentRoute` — Preflight's headset check (#33)
/// needs this distinct from mere device *presence* (an attached A2DP device
/// is not proof the communication mic route is engaged).
enum AudioRoute {
  /// A Bluetooth handsfree device (SCO/BLE/hearing aid) is the active
  /// communication route.
  bluetoothHeadset,

  /// A wired or USB headset is the active route.
  wired,

  /// Voice is on the phone's own speaker/earpiece — usable, but not the
  /// preferred route for riding.
  builtInSpeaker,

  /// No channel to ask (iOS, desktop, web) or the platform couldn't say —
  /// never treated as a failure.
  unknown,
}
