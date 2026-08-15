import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import '../../../../core/utils/logger.dart';

/// What the transmit stream is carrying, which decides how libopus is told to
/// model it.
///
/// Opus is not content-agnostic. [Application.voip] puts it in a speech-first
/// mode built around a vocal-tract model (SILK's LPC/long-term prediction) —
/// excellent on a voice, and audibly wrong on music: sustained tones and
/// cymbals get the warbling, smeared quality of a signal being fitted to a
/// model that does not describe it. [Application.audio] drops that assumption
/// and optimises for general audio instead.
///
/// The mode is fixed at encoder-construction time, so switching it means
/// rebuilding the encoder. That is fine here: it changes only when the user
/// starts or stops a music cast, not per frame.
enum OpusEncodeProfile {
  /// Speech. The default, and what the channel carries almost all the time.
  voice(Application.voip),

  /// A music cast is mixed into the outgoing stream — see MusicMixer.
  music(Application.audio);

  const OpusEncodeProfile(this.application);

  final Application application;
}

/// Opus codec for the 16 kHz mono transmit stream.
///
/// PCM16 at 16 kHz costs 256 kbps on the wire — fine on an idle LAN, but on
/// a lossy hotspot link between two motorcycles every dropped ~660-byte
/// datagram is 20 ms of missing speech, and over BLE that bandwidth simply
/// doesn't exist. Opus brings a 20 ms frame down to ~40-80 bytes
/// (~20-30 kbps) with better-than-PCM speech quality, which both slashes the
/// loss rate (smaller packets, less airtime) and makes Bluetooth audio
/// possible at all.
///
/// How the signal is modelled is chosen per [OpusEncodeProfile], because a
/// music cast is not speech and encoding it as though it were is audible.
///
/// The native libopus is loaded once via [ensureInitialized]; when loading
/// fails (unsupported desktop platform, missing binary) [isAvailable] stays
/// false and callers fall back to raw PCM16 packets.
class OpusAudioCodec {
  static bool _initialized = false;
  static bool get isAvailable => _initialized;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      initOpus(await opus_flutter.load());
      _initialized = true;
      Logger.diagnostic('codec: Opus initialized (${getOpusVersion()})');
    } catch (e) {
      // Diagnostic, loudly. Losing Opus is not a cosmetic fallback: PCM16 is
      // roughly an order of magnitude more bytes for the same 20 ms of speech,
      // and a link that carried a conversation comfortably under Opus can be
      // saturated by the same conversation under PCM16. "It sounded terrible
      // on that phone" and "Opus failed to load on that phone" are the same
      // sentence, and nothing in a release build used to say the second half.
      Logger.diagnostic(
        'codec: Opus UNAVAILABLE — falling back to PCM16, which costs '
        'several times the bandwidth per frame and may not fit the link: $e',
      );
    }
  }

  SimpleOpusEncoder? _encoder;
  OpusEncodeProfile _profile = OpusEncodeProfile.voice;

  /// Switches how the encoder models the signal. The current encoder is
  /// destroyed so the next [encode] builds one in the new mode; a no-op when
  /// the profile is unchanged, so callers can set it freely.
  void setProfile(OpusEncodeProfile profile) {
    if (_profile == profile) return;
    _profile = profile;
    _encoder?.destroy();
    _encoder = null;
    Logger.log('Opus encoder profile: ${profile.name}');
  }

  // One decoder per sender: an Opus stream is stateful (prediction across
  // frames), and a WiFi channel can carry several senders at once.
  final Map<String, SimpleOpusDecoder> _decoders = {};

  /// Encodes one 20 ms / 320-sample frame. Returns null when Opus is
  /// unavailable or the frame has an unexpected length (callers then send
  /// PCM16 instead).
  Uint8List? encode(List<double> samples) {
    if (!_initialized) return null;
    // Opus only accepts exact frame sizes (2.5/5/10/20/40/60 ms).
    if (samples.length != 320) return null;
    try {
      _encoder ??= SimpleOpusEncoder(
        sampleRate: 16000,
        channels: 1,
        application: _profile.application,
      );
      final pcm = Int16List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        pcm[i] = (samples[i].clamp(-1.0, 1.0) * 32767).round().clamp(
          -32768,
          32767,
        );
      }
      return _encoder!.encode(input: pcm);
    } catch (e) {
      _noteFailure('encode', e);
      return null;
    }
  }

  // Codec failures come per frame — fifty a second while whatever broke stays
  // broken — so they are counted and reported at a rate instead of logged
  // individually. The count is the diagnostic anyway: one failed frame is a
  // glitch nobody hears, a sustained rate is why a peer sounds like static.
  int _encodeFailures = 0;
  int _decodeFailures = 0;
  DateTime _lastFailureLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _failureLogInterval = Duration(seconds: 15);

  void _noteFailure(String stage, Object error) {
    if (stage == 'encode') {
      _encodeFailures++;
    } else {
      _decodeFailures++;
    }
    final now = DateTime.now();
    if (now.difference(_lastFailureLogAt) < _failureLogInterval) return;
    _lastFailureLogAt = now;
    Logger.diagnostic(
      'codec: Opus failing — $_encodeFailures encode / $_decodeFailures '
      'decode errors so far; latest on $stage: $error',
    );
  }

  /// Decodes one Opus packet from [senderId] back to normalized samples.
  /// Returns null when Opus is unavailable or the packet is corrupt.
  List<double>? decode(Uint8List packet, String senderId) {
    if (!_initialized) return null;
    try {
      final decoder = _decoders[senderId] ??= SimpleOpusDecoder(
        sampleRate: 16000,
        channels: 1,
      );
      final pcm = decoder.decode(input: packet);
      // Typed list: a plain List<double> would box every decoded sample,
      // 16k allocations/sec per talking peer.
      final samples = Float64List(pcm.length);
      for (var i = 0; i < pcm.length; i++) {
        samples[i] = pcm[i] / 32768.0;
      }
      return samples;
    } catch (e) {
      _noteFailure('decode', e);
      return null;
    }
  }

  /// Frees native encoder/decoder state. The codec stays usable — encoders
  /// and decoders are re-created lazily on the next call.
  void release() {
    _encoder?.destroy();
    _encoder = null;
    resetDecoders();
  }

  /// Frees per-sender decoder state without touching the encoder. Call after
  /// a detected reconnect: Opus decoding is stateful (prediction across
  /// frames), so a stale decoder left over from before a drop can produce
  /// garbled audio once a sender resumes — decoders are recreated lazily.
  void resetDecoders() {
    for (final decoder in _decoders.values) {
      decoder.destroy();
    }
    _decoders.clear();
  }
}
