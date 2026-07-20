import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import '../../../../core/utils/logger.dart';

/// Opus voice codec for the 16 kHz mono transmit stream.
///
/// PCM16 at 16 kHz costs 256 kbps on the wire — fine on an idle LAN, but on
/// a lossy hotspot link between two motorcycles every dropped ~660-byte
/// datagram is 20 ms of missing speech, and over BLE that bandwidth simply
/// doesn't exist. Opus VOIP mode brings a 20 ms frame down to ~40-80 bytes
/// (~20-30 kbps) with better-than-PCM speech quality, which both slashes the
/// loss rate (smaller packets, less airtime) and makes Bluetooth audio
/// possible at all.
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
      Logger.log('Opus initialized: ${getOpusVersion()}');
    } catch (e) {
      Logger.log('Opus unavailable, falling back to PCM16: $e');
    }
  }

  SimpleOpusEncoder? _encoder;

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
        application: Application.voip,
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
      Logger.log('Opus encode failed: $e');
      return null;
    }
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
      Logger.log('Opus decode failed: $e');
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
