/// What the outgoing audio stream is carrying.
///
/// The channel knows this and the codec cannot infer it: a music cast is
/// mixed into the same 20 ms frames as speech and looks identical by the time
/// it reaches the encoder. Declaring it lets the transport pick a codec
/// configuration that matches the signal — speech coders model a vocal tract,
/// which music does not have, and the mismatch is audible as warble and smear
/// on sustained tones and cymbals.
enum AudioProfile {
  /// Speech. What the channel carries almost all the time.
  voice,

  /// Speech with a system-audio (music) cast mixed on top of it.
  music,
}
