/// A single block of audio samples together with its pre-computed RMS level.
///
/// Emitted by [AudioCubit] at mic-capture rate (~100 Hz). Consumers that only
/// need the level can read [rms]; consumers that need the waveform read [samples].
class AudioFrame {
  final double rms;
  final List<double> samples;

  const AudioFrame({required this.rms, required this.samples});
}
