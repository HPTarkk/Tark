import '../entity/audio_engine_status.dart';
import '../entity/audio_frame.dart';

// ── Wire format constants ───────────────────────────────────────────────────

/// Sample rate audio is transmitted at. 16 kHz is plenty for intelligible
/// voice (telephony-grade) and keeps bandwidth + per-packet size low so
/// packets never fragment on the wire — the main source of dropouts when
/// streaming raw mic-rate audio over UDP.
const int kTxSampleRate = 16000;

/// 20 ms per network frame: 320 samples @ 16 kHz × 2 bytes (PCM16) = 640
/// bytes of payload, safely under the ~1472-byte UDP-safe MTU even with
/// headers — guarantees one frame == one unfragmented IP packet.
const int kFrameSamples = 320;

/// Duplex audio engine: mic capture → DSP → fixed 16 kHz frames out, and
/// received network audio → jitter buffer → speaker.
///
/// Implementations own the platform audio device. The process-wide device
/// is a singleton while engine instances come and go per session, so
/// implementations must guarantee that a stale [dispose] never tears down
/// a newer session's engine (see AudioEngineImpl's epoch/lock guards).
abstract interface class AudioEngine {
  /// Audio-rate stream of fixed-size (20 ms @ 16 kHz) outgoing frames.
  Stream<AudioFrame> get frames;

  /// Emits whenever permission/started state changes.
  Stream<AudioEngineStatus> get status;

  /// Current status, readable synchronously.
  AudioEngineStatus get currentStatus;

  /// Request mic permission and start the duplex engine.
  Future<void> start();

  /// Apply the audio processing chain (normalisation + high-pass + noise
  /// gate) to a fixed-size 16 kHz mic frame before it is transmitted.
  ///
  /// [voxThreshold] ties the internal noise gate to the user's VOX setting:
  /// it scales down as the VOX threshold is lowered and disables entirely
  /// at 0, so a VOX threshold of "0 = always on" truly means no gating
  /// anywhere in the chain (not just at the frame level).
  List<double> processForTransmit(List<double> samples, double voxThreshold);

  /// Set spectral noise suppression strength (0 = off, 1 = maximum).
  /// Applied to the mic signal before VOX/visualizer/transmit.
  void setNoiseSuppression(double strength);

  /// Feed received network audio (16 kHz PCM) into the jitter buffer,
  /// upsampling to the device's output rate first.
  /// [seq] is the sender's packet sequence number and [senderId] identifies
  /// which peer sent it — the jitter buffer tracks sequence gaps per sender
  /// so one participant's stream can't desync playback of another's (a WiFi
  /// channel can have more than 2 participants).
  void playReceived(List<double> samples, int seq, String senderId);

  /// Clears jitter-buffer playback state (queued audio, sequence tracking).
  /// Call after a detected reconnect so stale buffered audio doesn't play
  /// back "late" once the link recovers.
  void resetPlayback();

  /// Stop the engine (unless a newer session already owns it) and release
  /// this instance's resources. Safe to call while [start] is in flight.
  Future<void> dispose();
}
