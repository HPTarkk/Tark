import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:opus_dart/wrappers/opus_defines.dart' as defines;
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/opus_tuning.dart';
import '../../domain/service/fec_gap_tracker.dart';
import '../../domain/service/opus_tuner.dart';
import 'controlled_opus.dart';
import 'controlled_opus_stub.dart'
    if (dart.library.ffi) 'controlled_opus_ffi.dart';

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
  voice(Application.voip, defines.OPUS_APPLICATION_VOIP),

  /// A music cast is mixed into the outgoing stream — see MusicMixer.
  music(Application.audio, defines.OPUS_APPLICATION_AUDIO);

  const OpusEncodeProfile(this.application, this.applicationCode);

  /// For `opus_dart`'s encoder, which takes the enum.
  final Application application;

  /// The same choice as libopus's own integer, for the controlled encoder,
  /// which calls `opus_encoder_create` directly.
  final int applicationCode;
}

/// One decoded packet, and whatever the packet before it turned out to contain.
class OpusDecodeResult {
  const OpusDecodeResult(this.samples, {this.recoveredPrevious});

  /// The frame this packet carries.
  final List<double> samples;

  /// The frame *before* this one, reconstructed because it never arrived.
  ///
  /// Non-null only when exactly one packet was missing and the decoder could
  /// rebuild it — from the sender's in-band FEC copy where there is one, and
  /// from libopus's own concealment where there isn't. Callers must play it
  /// **before** [samples], at the missing packet's sequence number, so the
  /// jitter buffer sees a continuous stream and never conceals the gap itself.
  final List<double>? recoveredPrevious;
}

/// Opus codec for the mono transmit stream, at whichever [AudioFormatProfile]
/// [setFormatProfile] last set (default [AudioFormatProfile.legacy16k]).
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
/// ## Three rungs, each a working codec
///
/// 1. [ControlledOpusEncoder]/[ControlledOpusDecoder] — direct libopus
///    bindings. The only rung with **in-band FEC**, which is what makes a lost
///    packet recoverable instead of a hole, and the only one whose bitrate
///    tracks the link (see [applyTuning]).
/// 2. `opus_dart`'s own encoder/decoder. No FEC and no tuning, but the same
///    audio quality at a fixed bitrate — this is exactly what shipped before.
/// 3. Raw PCM16, when libopus did not load at all.
///
/// Falling from 1 to 2 is silent and safe by design: every native failure in
/// the bindings resolves to "no controlled codec here", and the rung below is
/// the previously shipping behaviour. Falling to 3 is loud, because it is not.
class OpusAudioCodec {
  static bool _initialized = false;
  static bool get isAvailable => _initialized;

  /// The `libopus` handle `opus_flutter` loaded, kept so the controlled codecs
  /// can bind against the *same* library instance `opus_dart` is using. Loading
  /// a second copy would put the encoder and decoder in different library
  /// instances — a stateful codec split across two libraries is a bug that
  /// would only ever appear at runtime.
  ///
  /// Typed as `Object?` because on web `opus_flutter.load()` returns a web_ffi
  /// library, which is not a `dart:ffi` `DynamicLibrary` and must not be named
  /// as one in code the web build compiles.
  static Object? _library;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      final library = await opus_flutter.load();
      initOpus(library);
      _library = library;
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

  ControlledOpusEncoder? _controlledEncoder;
  SimpleOpusEncoder? _encoder;
  OpusEncodeProfile _profile = OpusEncodeProfile.voice;

  /// The wire-format contract (rate, frame size) this codec currently runs.
  /// See [setFormatProfile].
  AudioFormatProfile _formatProfile = AudioFormatProfile.legacy16k;

  /// Whether the transmit path is running with in-band FEC. False means rung 2
  /// or 3 above — worth reporting, because it changes what a lossy link sounds
  /// like on the far end.
  bool get hasFec => _controlledEncoder != null;

  /// Current encoder settings. Held here rather than on the encoder so that
  /// rebuilding it — which [setProfile] does — restores the tuning the link
  /// was last measured to need instead of silently reverting to the default.
  OpusTuning _tuning = OpusTuner.initial;

  /// What the encoder is currently set to, for the session log. On rungs 2 and
  /// 3 this is what the link was measured to *want*, not what is in force —
  /// read it alongside [hasFec], which says whether anything could act on it.
  OpusTuning get tuning => _tuning;

  /// Retunes the live encoder for the measured link.
  ///
  /// A no-op when the tuning is unchanged, so the caller can hand this the
  /// grader's output on every measurement tick without thinking about it.
  /// Silently ignored on rungs 2 and 3, which have no knobs.
  void applyTuning(OpusTuning tuning) {
    if (tuning == _tuning) return;
    _tuning = tuning;
    final encoder = _controlledEncoder;
    if (encoder == null) return;
    if (!encoder.applyTuning(tuning)) {
      // The encoder still works — it is simply stuck on its previous settings.
      // Not fatal, and not worth a line per tick, so it is reported once and
      // the tuning is left alone from here.
      Logger.diagnostic(
        'codec: Opus rejected $tuning — encoder stays on its previous settings',
      );
      return;
    }
    Logger.log('Opus tuning: $tuning');
  }

  /// Switches how the encoder models the signal. The current encoder is
  /// destroyed so the next [encode] builds one in the new mode; a no-op when
  /// the profile is unchanged, so callers can set it freely.
  void setProfile(OpusEncodeProfile profile) {
    if (_profile == profile) return;
    _profile = profile;
    _releaseEncoder();
    Logger.log('Opus encoder profile: ${profile.name}');
  }

  /// Switches the negotiated wire format (see [AudioCapabilityNegotiator]).
  /// A no-op when unchanged, so a caller can hand this the negotiator's
  /// result on every presence tick without checking first.
  ///
  /// Rebuilds the encoder (its sample rate is fixed at construction, same as
  /// [OpusEncodeProfile]) and resets every per-sender decoder — a decoder
  /// built for the old rate/frame size cannot continue decoding mid-stream,
  /// same as [resetDecoders]' own reasoning for a detected reconnect.
  void setFormatProfile(AudioFormatProfile profile) {
    if (_formatProfile == profile) return;
    _formatProfile = profile;
    _releaseEncoder();
    resetDecoders();
    Logger.log('Opus wire format: ${profile.label}');
  }

  // One decoder per sender: an Opus stream is stateful (prediction across
  // frames), and a WiFi channel can carry several senders at once.
  final Map<String, ControlledOpusDecoder> _controlledDecoders = {};
  final Map<String, SimpleOpusDecoder> _decoders = {};

  /// Spots the one-packet gaps that FEC can fill — and, just as importantly,
  /// refuses to see one where reordering has merely made it look that way. See
  /// [FecGapTracker].
  final FecGapTracker _gaps = FecGapTracker();

  /// Encodes one frame sized per the active [AudioFormatProfile]. Returns
  /// null when Opus is unavailable or the frame has an unexpected length
  /// (callers then send PCM16 instead).
  Uint8List? encode(List<double> samples) {
    if (!_initialized) return null;
    // Opus only accepts exact frame sizes (2.5/5/10/20/40/60 ms).
    if (samples.length != _formatProfile.frameSamples) {
      return null;
    }
    try {
      final pcm = Int16List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        pcm[i] = (samples[i].clamp(-1.0, 1.0) * 32767).round().clamp(
          -32768,
          32767,
        );
      }
      return _ensureEncoder()?.call(pcm);
    } catch (e) {
      _noteFailure('encode', e);
      return null;
    }
  }

  /// Resolves the best available encoder, building it on first use.
  ///
  /// Returns the encode call itself rather than an object so the two rungs —
  /// which share no supertype, one being `opus_dart`'s — can be selected once
  /// here instead of at every call site.
  Uint8List Function(Int16List)? _ensureEncoder() {
    final controlled = _controlledEncoder;
    if (controlled != null) return controlled.encode;
    final simple = _encoder;
    if (simple != null) return (pcm) => simple.encode(input: pcm);

    final built = tryCreateControlledOpusEncoder(
      library: _library,
      sampleRate: _formatProfile.sampleRateHz,
      channels: 1,
      application: _profile.applicationCode,
    );
    if (built != null) {
      _controlledEncoder = built;
      built.applyTuning(_tuning);
      Logger.diagnostic(
        'codec: Opus encoder with in-band FEC (${_profile.name}, $_tuning)',
      );
      return built.encode;
    }

    // Rung 2. Not a failure worth alarming about — it is what every build
    // before FEC did — but it is worth being able to see in a log, because
    // "their phone sounds torn up under loss and mine doesn't" has this as its
    // most likely explanation.
    Logger.diagnostic(
      'codec: no controlled Opus encoder — encoding without in-band FEC',
    );
    final simpleEncoder = SimpleOpusEncoder(
      sampleRate: _formatProfile.sampleRateHz,
      channels: 1,
      application: _profile.application,
    );
    _encoder = simpleEncoder;
    return (pcm) => simpleEncoder.encode(input: pcm);
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
  ///
  /// [seq] is the packet's sequence number, used only to notice that exactly
  /// one packet went missing — in which case the result also carries that
  /// frame, rebuilt from the FEC copy this packet is carrying for it. Returns
  /// null when Opus is unavailable or the packet is corrupt.
  OpusDecodeResult? decode(Uint8List packet, String senderId, int seq) {
    if (!_initialized) return null;
    try {
      final controlled = _controlledDecoder(senderId);
      if (controlled != null) {
        return _decodeControlled(controlled, senderId, seq, packet);
      }

      final decoder = _decoders[senderId] ??= SimpleOpusDecoder(
        sampleRate: _formatProfile.sampleRateHz,
        channels: 1,
      );
      // Tracked even on this rung, which cannot recover anything: the sender
      // may move onto a controlled decoder after a reset, and starting it with
      // no sequence history would cost a recovery, not correctness.
      _gaps.observe(senderId, seq);
      final pcm = decoder.decode(input: packet);
      // Typed list: a plain List<double> would box every decoded sample,
      // 16k allocations/sec per talking peer.
      final samples = Float64List(pcm.length);
      for (var i = 0; i < pcm.length; i++) {
        samples[i] = pcm[i] / 32768.0;
      }
      return OpusDecodeResult(samples);
    } catch (e) {
      _noteFailure('decode', e);
      return null;
    }
  }

  OpusDecodeResult _decodeControlled(
    ControlledOpusDecoder decoder,
    String senderId,
    int seq,
    Uint8List packet,
  ) {
    // Exactly one packet missing, and we have decoder state to rebuild it from.
    // Wider gaps are left to the jitter buffer: Opus carries a copy of the
    // *immediately* preceding frame and no further back, so a second missing
    // packet is genuinely gone.
    final recoverable = _gaps.observe(senderId, seq);

    List<double>? recovered;
    if (recoverable) {
      try {
        // Must run before the normal decode of the same packet: decode_fec=1
        // pulls out the redundant copy of the previous frame and leaves the
        // decoder positioned to decode this one next. The reverse order
        // produces the current frame twice.
        recovered = decoder.decodeFec(packet, _formatProfile.frameSamples);
      } catch (e) {
        // The packet carried no usable FEC and concealment failed too. The gap
        // then falls through to the jitter buffer exactly as it did before.
        _noteFailure('decode', e);
      }
    }

    final samples = decoder.decode(packet);
    return OpusDecodeResult(samples, recoveredPrevious: recovered);
  }

  /// The controlled decoder for [senderId], built on first packet. Null once
  /// the bindings have been found unavailable, so the fallback below is tried
  /// once per sender rather than once per packet.
  ControlledOpusDecoder? _controlledDecoder(String senderId) {
    final existing = _controlledDecoders[senderId];
    if (existing != null) return existing;
    if (_decoders.containsKey(senderId)) return null; // already on the fallback
    final built = tryCreateControlledOpusDecoder(
      library: _library,
      sampleRate: _formatProfile.sampleRateHz,
      channels: 1,
    );
    if (built == null) return null;
    _controlledDecoders[senderId] = built;
    return built;
  }

  /// Frees native encoder/decoder state. The codec stays usable — encoders
  /// and decoders are re-created lazily on the next call.
  void release() {
    _releaseEncoder();
    resetDecoders();
  }

  void _releaseEncoder() {
    _controlledEncoder?.destroy();
    _controlledEncoder = null;
    _encoder?.destroy();
    _encoder = null;
  }

  /// Frees per-sender decoder state without touching the encoder. Call after
  /// a detected reconnect: Opus decoding is stateful (prediction across
  /// frames), so a stale decoder left over from before a drop can produce
  /// garbled audio once a sender resumes — decoders are recreated lazily.
  void resetDecoders() {
    for (final decoder in _controlledDecoders.values) {
      decoder.destroy();
    }
    _controlledDecoders.clear();
    for (final decoder in _decoders.values) {
      decoder.destroy();
    }
    _decoders.clear();
    // Cleared with the decoders it describes: a sequence remembered across a
    // reconnect would make the first packet after it look like a one-packet
    // gap, and hand a recovery attempt to a decoder that has no state to build
    // it from.
    _gaps.clear();
  }
}
