import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/settings/noise_suppression_engine.dart';
import '../entity/audio_engine_status.dart';
import '../entity/audio_frame.dart';

/// Duplex audio engine: mic capture → DSP → fixed-format frames out, and
/// received network audio → jitter buffer → speaker.
///
/// Wire format (sample rate, frame size) is [AudioFormatProfile.legacy16k]
/// today — 16 kHz is plenty for intelligible voice (telephony-grade) and
/// keeps per-packet size low so packets never fragment on the wire, the main
/// source of dropouts when streaming raw mic-rate audio over UDP. #28
/// introduces negotiating up to [AudioFormatProfile.hd24k] on capable links;
/// see [AudioFormatProfile.supported].
///
/// Implementations own the platform audio device. The process-wide device
/// is a singleton while engine instances come and go per session, so
/// implementations must guarantee that a stale [dispose] never tears down
/// a newer session's engine (see AudioEngineImpl's epoch/lock guards).
abstract interface class AudioEngine {
  /// Audio-rate stream of fixed-size outgoing frames, sized per the active
  /// [AudioFormatProfile].
  Stream<AudioFrame> get frames;

  /// Audio-rate stream of incoming frames handed to [playReceived], so the
  /// UI can show what the channel is playing rather than only what the mic
  /// is hearing. Tapped off the wire, ahead of the jitter buffer.
  Stream<AudioFrame> get receivedFrames;

  /// Emits whenever permission/started state changes.
  Stream<AudioEngineStatus> get status;

  /// Current status, readable synchronously.
  AudioEngineStatus get currentStatus;

  /// Request mic permission and start the duplex engine.
  Future<void> start();

  /// Switches the wire format the capture/playback chains run at, once
  /// negotiation (`AudioCapabilityNegotiator`, `feature/transfer`) has
  /// settled on a new mutual profile with the peers currently on the
  /// channel.
  ///
  /// A hot-swap, not a device reopen: the platform mic/speaker stay open at
  /// whatever rate the OS gave them, and only the resamplers, frame
  /// accumulator, and noise-suppression chain between them and the wire are
  /// rebuilt — so a legitimate profile transition cannot itself cause a
  /// screen-off disconnect, a route-change deadlock, or any of the other
  /// reliability properties `#26`'s baseline pinned down. A no-op when
  /// [profile] is unchanged, so a caller can pass this the negotiator's
  /// result on every presence tick without checking first.
  void setWireFormat(AudioFormatProfile profile);

  /// Apply the audio processing chain (normalisation + high-pass + noise
  /// gate) to a fixed-size mic frame, sized per the active
  /// [AudioFormatProfile], before it is transmitted.
  ///
  /// [voxLevel] is the **resolved** absolute level the VOX gate is comparing
  /// frames against this instant — `NoiseFloorTracker.thresholdFor`'s output,
  /// not the stored setting, which is a margin above the measured background
  /// and means nothing on its own. It ties the internal noise gate to VOX: it
  /// scales down as the gate's level drops and disables entirely at 0, so VOX
  /// off truly means no gating anywhere in the chain, not just at frame level.
  List<double> processForTransmit(List<double> samples, double voxLevel);

  /// Set noise suppression strength (0 = off, 1 = maximum) for whichever
  /// engine is currently selected via [setNoiseSuppressionEngine]. Applied
  /// to the mic signal before VOX/visualizer/transmit.
  void setNoiseSuppression(double strength);

  /// Select which noise suppression algorithm runs on the mic signal —
  /// spectral, rnnoise, or [NoiseSuppressionEngine.both] cascaded. If
  /// rnnoise isn't available on this platform/build, implementations fall
  /// back to spectral suppression silently (for `both` too).
  void setNoiseSuppressionEngine(NoiseSuppressionEngine engine);

  /// Linear gain applied to received voice on its way into the jitter buffer.
  /// 1.0 (the default) passes samples through untouched, and implementations
  /// must skip the work entirely at that value — this is the RX hot path and
  /// the overwhelming majority of sessions never move it.
  ///
  /// Above 1.0 the boost is soft-limited rather than clipped. A rider raising
  /// this is trying to hear a voice over road noise, and hard clipping would
  /// hand them a louder but *less* intelligible signal, which defeats the
  /// point. See [RidingPreset.playbackGain].
  void setPlaybackGain(double gain);

  /// Feed received network audio (PCM at the active [AudioFormatProfile]'s
  /// rate) into the jitter buffer, upsampling to the device's output rate
  /// first.
  /// [seq] is the sender's packet sequence number and [senderId] identifies
  /// which peer sent it — the jitter buffer tracks sequence gaps per sender
  /// so one participant's stream can't desync playback of another's (a WiFi
  /// channel can have more than 2 participants).
  void playReceived(List<double> samples, int seq, String senderId);

  /// Media analog of [playReceived] — see #30. [samples] are at 48 kHz (the
  /// fixed rate every negotiated media profile uses —
  /// `AudioFormatProfile.media48kStereo`/`media48kMono`), interleaved when
  /// [channels] is 2. [seq]/[senderId] carry the same per-sender, independent
  /// sequence-space contract [playReceived] does — media's own jitter buffer
  /// tracks it separately, so one stream's loss/reorder can never affect the
  /// other's.
  ///
  /// Mixed into the device's single output alongside voice, downmixed to
  /// mono first when [channels] is 2: the underlying output path is mono
  /// (see [playReceived]'s wire format), and mixing genuinely separate L/R
  /// audio into it would require a stereo-capable output path this engine
  /// doesn't have. That only affects local playback — the wire stream stays
  /// genuinely stereo where negotiated.
  void playReceivedMedia(
    List<double> samples,
    int channels,
    int seq,
    String senderId,
  );

  /// Clears jitter-buffer playback state (queued audio, sequence tracking)
  /// for both voice and media. Call after a detected reconnect so stale
  /// buffered audio doesn't play back "late" once the link recovers.
  void resetPlayback();

  /// Stop the engine (unless a newer session already owns it) and release
  /// this instance's resources. Safe to call while [start] is in flight.
  Future<void> dispose();
}
