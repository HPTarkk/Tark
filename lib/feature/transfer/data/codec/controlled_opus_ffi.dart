import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:opus_dart/wrappers/opus_defines.dart' as defines;

import '../../domain/entity/opus_tuning.dart';
import 'controlled_opus.dart';

/// Opaque native handles, matching `opus_dart`'s own declarations. The pointers
/// are created and freed entirely on this side, so the two never meet.
final class _OpusEncoder extends Opaque {}

final class _OpusDecoder extends Opaque {}

// opus.h:
//   OpusEncoder *opus_encoder_create(opus_int32 Fs, int channels,
//                                    int application, int *error);
typedef _EncCreateNative =
    Pointer<_OpusEncoder> Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _EncCreateDart =
    Pointer<_OpusEncoder> Function(int, int, int, Pointer<Int32>);

// opus.h:
//   opus_int32 opus_encode(OpusEncoder *st, const opus_int16 *pcm,
//                          int frame_size, unsigned char *data,
//                          opus_int32 max_data_bytes);
typedef _EncodeNative =
    Int32 Function(
      Pointer<_OpusEncoder>,
      Pointer<Int16>,
      Int32,
      Pointer<Uint8>,
      Int32,
    );
typedef _EncodeDart =
    int Function(
      Pointer<_OpusEncoder>,
      Pointer<Int16>,
      int,
      Pointer<Uint8>,
      int,
    );

// opus.h:
//   int opus_encoder_ctl(OpusEncoder *st, int request, ...);
//
// Genuinely variadic, and declared as such rather than as a plain
// three-argument function. The shortcut works on Android/AArch64, where AAPCS64
// passes variadic integers in the same registers as fixed ones, and breaks on
// Apple's AArch64 ABI, which puts every variadic argument on the stack. iOS is
// built blind here (no Mac), so a difference that only shows up on the platform
// nobody can test is exactly the one to declare correctly rather than to get
// lucky with.
typedef _CtlNative =
    Int32 Function(Pointer<_OpusEncoder>, Int32, VarArgs<(Int32,)>);
typedef _CtlDart = int Function(Pointer<_OpusEncoder>, int, int);

// opus.h: void opus_encoder_destroy(OpusEncoder *st);
typedef _EncDestroyNative = Void Function(Pointer<_OpusEncoder>);
typedef _EncDestroyDart = void Function(Pointer<_OpusEncoder>);

// opus.h:
//   OpusDecoder *opus_decoder_create(opus_int32 Fs, int channels, int *error);
typedef _DecCreateNative =
    Pointer<_OpusDecoder> Function(Int32, Int32, Pointer<Int32>);
typedef _DecCreateDart = Pointer<_OpusDecoder> Function(int, int, Pointer<Int32>);

// opus.h:
//   int opus_decode_float(OpusDecoder *st, const unsigned char *data,
//                         opus_int32 len, float *pcm, int frame_size,
//                         int decode_fec);
typedef _DecodeFloatNative =
    Int32 Function(
      Pointer<_OpusDecoder>,
      Pointer<Uint8>,
      Int32,
      Pointer<Float>,
      Int32,
      Int32,
    );
typedef _DecodeFloatDart =
    int Function(
      Pointer<_OpusDecoder>,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      int,
      int,
    );

// opus.h: void opus_decoder_destroy(OpusDecoder *st);
typedef _DecDestroyNative = Void Function(Pointer<_OpusDecoder>);
typedef _DecDestroyDart = void Function(Pointer<_OpusDecoder>);

/// Ceiling on one encoded packet, from `opus_dart`'s own `maxDataBytes`
/// (3 × 1275). Passed to `opus_encode` as `max_data_bytes`, where it acts as a
/// hard bitrate ceiling — so it is deliberately left at the largest a valid
/// Opus packet can be, and the actual bitrate is set through the CTL instead.
/// A 20 ms voice frame at these bitrates is 30–80 bytes; this costs one 3.8 kB
/// allocation for the life of the encoder.
const int _kMaxPacketBytes = 3 * 1275;

/// Samples in the longest packet Opus can produce: 120 ms. Both buffers are
/// sized to it so no legal frame from any peer can overrun them, which is the
/// same reasoning behind `opus_dart`'s `maxSamplesPerPacket`.
int _maxSamplesPerPacket(int sampleRate, int channels) =>
    (sampleRate * channels * 120 / 1000).ceil();

/// The library `opus_flutter` loaded, or null if it handed back something else
/// (a web_ffi library, or nothing at all).
DynamicLibrary? _asDynamicLibrary(Object? library) =>
    library is DynamicLibrary ? library : null;

class _FfiControlledOpusEncoder implements ControlledOpusEncoder {
  _FfiControlledOpusEncoder._(
    this._encoder,
    this._encode,
    this._ctl,
    this._destroy,
    this._maxFrameSamples,
  ) : _pcmBuffer = malloc<Int16>(_maxFrameSamples),
      _packetBuffer = malloc<Uint8>(_kMaxPacketBytes);

  final Pointer<_OpusEncoder> _encoder;
  final _EncodeDart _encode;
  final _CtlDart _ctl;
  final _EncDestroyDart _destroy;
  final int _maxFrameSamples;

  // Allocated once and reused, not per frame: this runs fifty times a second
  // for the whole call, and the mic path already shares the UI isolate.
  final Pointer<Int16> _pcmBuffer;
  final Pointer<Uint8> _packetBuffer;

  bool _destroyed = false;

  /// Settings applied at creation purely to confirm the CTL path works. The
  /// values match [OpusTuner.initial], so a session that never measures
  /// anything is already tuned correctly.
  static const _probeTuning = OpusTuning(
    bitrate: 20000,
    packetLossPerc: 0,
    complexity: 5,
  );

  /// Creates the encoder and proves it is actually controllable before handing
  /// it back.
  ///
  /// The proof is the point. Everything this class exists for happens through
  /// `opus_encoder_ctl`, and a binding subtly wrong for a platform's ABI would
  /// not fail at lookup — it would return a nonsense code, or appear to succeed
  /// while setting nothing. So creation applies the settings it will rely on
  /// and checks every return, and any rejection discards the encoder whole. The
  /// caller then uses `SimpleOpusEncoder`, i.e. exactly what shipped before FEC.
  static ControlledOpusEncoder? tryCreate({
    required Object? library,
    required int sampleRate,
    required int channels,
    required int application,
  }) {
    final lib = _asDynamicLibrary(library);
    if (lib == null) return null;
    try {
      final create = lib.lookupFunction<_EncCreateNative, _EncCreateDart>(
        'opus_encoder_create',
      );
      final encode = lib.lookupFunction<_EncodeNative, _EncodeDart>(
        'opus_encode',
      );
      final ctl = lib.lookupFunction<_CtlNative, _CtlDart>('opus_encoder_ctl');
      final destroy = lib.lookupFunction<_EncDestroyNative, _EncDestroyDart>(
        'opus_encoder_destroy',
      );

      // nullptr for the error out-param: libopus guards every write to it with
      // `if (error)`, and a null return already says creation failed, so this
      // saves an allocation on a path with nothing else to report.
      final encoder = create(sampleRate, channels, application, nullptr);
      if (encoder == nullptr) return null;

      // In-band FEC is switched on here, once, and never switched off. It costs
      // nothing while OPUS_SET_PACKET_LOSS_PERC is 0 — libopus spends bits on
      // the redundant copy only in proportion to the budgeted loss — so leaving
      // it on removes the whole class of bug where a link degrades and
      // something forgot to enable FEC in time to matter.
      if (ctl(encoder, defines.OPUS_SET_INBAND_FEC_REQUEST, 1) !=
          defines.OPUS_OK) {
        destroy(encoder);
        return null;
      }

      final created = _FfiControlledOpusEncoder._(
        encoder,
        encode,
        ctl,
        destroy,
        _maxSamplesPerPacket(sampleRate, channels),
      );
      // The rest of the settings double as the ABI probe described above.
      if (!created.applyTuning(_probeTuning)) {
        created.destroy();
        return null;
      }
      return created;
    } catch (_) {
      // A missing symbol, an unexpected ABI, a library that isn't libopus at
      // all. All of it means "no controlled encoder here", which is survivable.
      return null;
    }
  }

  @override
  bool applyTuning(OpusTuning tuning) {
    if (_destroyed) return false;
    return _set(defines.OPUS_SET_BITRATE_REQUEST, tuning.bitrate) &&
        _set(defines.OPUS_SET_COMPLEXITY_REQUEST, tuning.complexity) &&
        _set(defines.OPUS_SET_PACKET_LOSS_PERC_REQUEST, tuning.packetLossPerc);
  }

  bool _set(int request, int value) {
    try {
      return _ctl(_encoder, request, value) == defines.OPUS_OK;
    } catch (_) {
      return false;
    }
  }

  @override
  Uint8List encode(Int16List pcm) {
    if (_destroyed) {
      throw StateError('encode() on a destroyed ControlledOpusEncoder');
    }
    if (pcm.length > _maxFrameSamples) {
      throw ArgumentError(
        'frame of ${pcm.length} samples exceeds the $_maxFrameSamples this '
        'encoder was built for',
      );
    }
    _pcmBuffer.asTypedList(pcm.length).setAll(0, pcm);
    final written = _encode(
      _encoder,
      _pcmBuffer,
      pcm.length,
      _packetBuffer,
      _kMaxPacketBytes,
    );
    if (written < defines.OPUS_OK) throw OpusNativeException('encode', written);
    // Copied out of native memory: the packet outlives this call — it goes to a
    // socket, and on the WiFi path to several — while the buffer is reused by
    // the next frame 20 ms from now.
    return Uint8List.fromList(_packetBuffer.asTypedList(written));
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _destroy(_encoder);
    malloc.free(_pcmBuffer);
    malloc.free(_packetBuffer);
  }
}

class _FfiControlledOpusDecoder implements ControlledOpusDecoder {
  _FfiControlledOpusDecoder._(
    this._decoder,
    this._decodeFloat,
    this._destroy,
    this._maxFrameSamples,
  ) : _pcmBuffer = malloc<Float>(_maxFrameSamples);

  final Pointer<_OpusDecoder> _decoder;
  final _DecodeFloatDart _decodeFloat;
  final _DecDestroyDart _destroy;
  final int _maxFrameSamples;
  final Pointer<Float> _pcmBuffer;

  bool _destroyed = false;

  static ControlledOpusDecoder? tryCreate({
    required Object? library,
    required int sampleRate,
    required int channels,
  }) {
    final lib = _asDynamicLibrary(library);
    if (lib == null) return null;
    try {
      final create = lib.lookupFunction<_DecCreateNative, _DecCreateDart>(
        'opus_decoder_create',
      );
      final decodeFloat = lib
          .lookupFunction<_DecodeFloatNative, _DecodeFloatDart>(
            'opus_decode_float',
          );
      final destroy = lib.lookupFunction<_DecDestroyNative, _DecDestroyDart>(
        'opus_decoder_destroy',
      );
      final decoder = create(sampleRate, channels, nullptr);
      if (decoder == nullptr) return null;
      return _FfiControlledOpusDecoder._(
        decoder,
        decodeFloat,
        destroy,
        _maxSamplesPerPacket(sampleRate, channels),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  List<double> decode(Uint8List packet) => _run(packet, _maxFrameSamples, 0);

  @override
  List<double> decodeFec(Uint8List packet, int missingSamples) {
    // Clamped rather than trusted: frame_size is what libopus writes into the
    // buffer, and a caller asking for more than was allocated would be a native
    // overrun rather than an exception.
    final frameSize = missingSamples.clamp(1, _maxFrameSamples);
    return _run(packet, frameSize, 1);
  }

  List<double> _run(Uint8List packet, int frameSize, int decodeFec) {
    if (_destroyed) {
      throw StateError('decode() on a destroyed ControlledOpusDecoder');
    }
    // The packet has to reach native memory; there is no way to hand libopus a
    // Dart list directly. Allocated per call rather than into a reused buffer
    // because it is small (tens of bytes) and, unlike the PCM side, sized by
    // the sender rather than by us.
    final input = malloc<Uint8>(packet.length);
    try {
      input.asTypedList(packet.length).setAll(0, packet);
      final samples = _decodeFloat(
        _decoder,
        input,
        packet.length,
        _pcmBuffer,
        frameSize,
        decodeFec,
      );
      if (samples < defines.OPUS_OK) {
        throw OpusNativeException(
          decodeFec == 1 ? 'decode(fec)' : 'decode',
          samples,
        );
      }
      // Float32List IS a List<double> in Dart, and libopus already hands back
      // normalised [-1, 1] floats — so this reaches the resampler and the
      // jitter buffer with no conversion pass at all. The previous path decoded
      // to int16 and walked every sample to divide by 32768.
      return Float32List.fromList(_pcmBuffer.asTypedList(samples));
    } finally {
      malloc.free(input);
    }
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _destroy(_decoder);
    malloc.free(_pcmBuffer);
  }
}

/// A native libopus failure, carrying the error code.
///
/// Deliberately not `opus_dart`'s `OpusException`: that renders itself by
/// calling `opus_strerror` through the package's own library handle, which is
/// initialised by `initOpus` — and these bindings are reachable in tests and on
/// paths where that may not have happened. The code is the diagnostic anyway.
class OpusNativeException implements Exception {
  const OpusNativeException(this.stage, this.errorCode);

  final String stage;
  final int errorCode;

  @override
  String toString() => 'OpusNativeException: $stage returned $errorCode';
}

ControlledOpusEncoder? tryCreateControlledOpusEncoder({
  required Object? library,
  required int sampleRate,
  required int channels,
  required int application,
}) => _FfiControlledOpusEncoder.tryCreate(
  library: library,
  sampleRate: sampleRate,
  channels: channels,
  application: application,
);

ControlledOpusDecoder? tryCreateControlledOpusDecoder({
  required Object? library,
  required int sampleRate,
  required int channels,
}) => _FfiControlledOpusDecoder.tryCreate(
  library: library,
  sampleRate: sampleRate,
  channels: channels,
);
