/// Direct bindings to the two `libopus` calls `opus_dart` cannot make for us.
///
/// ## Why the package is not enough
///
/// **Encoding.** `opus_dart` never binds `opus_encoder_ctl` — its FFI wrapper
/// covers only `opus_encoder_get_size/create/init/encode/destroy` — and it
/// hides both the native encoder pointer and its own library handle behind
/// private fields, so there is no seam to reach a CTL through from outside.
/// Bitrate, complexity and, above all, **in-band FEC** are unreachable through
/// the package at any level.
///
/// **Decoding.** `SimpleOpusDecoder` does expose a `fec` flag, but it cannot
/// work: the value it forwards to libopus as `frame_size` — a *sample* count —
/// is computed in *milliseconds* (`_packetDuration`, and `_estimateLoss` which
/// returns it unchanged). For this app's 20 ms frames that passes 20 where
/// libopus needs 320, so every FEC decode returns `OPUS_BUFFER_TOO_SMALL` and
/// the package turns it into a throw. The bug is latent for Tark today only
/// because nothing has ever asked it to conceal a packet.
///
/// FEC is the item the reliability roadmap calls the highest-value one for
/// riding, so both calls are bound here against the same `libopus` handle
/// `opus_flutter` already loaded. Nothing else about `opus_dart` changes.
///
/// Implementations come from `tryCreateControlledOpusEncoder` /
/// `tryCreateControlledOpusDecoder`, which resolve to real bindings where
/// dart:ffi exists and to stubs returning null on web. **Null is a supported
/// outcome, not an error** — the caller falls back to `opus_dart`'s own
/// encoder and decoder, which is exactly what shipped before FEC, so the worst
/// case of every failure here is the status quo.
library;

import 'dart:typed_data';

import '../../domain/entity/opus_tuning.dart';

/// An Opus encoder whose settings can be changed while it runs.
abstract interface class ControlledOpusEncoder {
  /// Encodes one frame of PCM16 and returns the Opus packet. Interleaved
  /// (L, R, L, R, ...) when the encoder was built for 2 channels, same
  /// convention libopus itself uses.
  ///
  /// Throws on a native error, like the `opus_dart` encoder it replaces, so the
  /// existing per-frame failure counting keeps working unchanged.
  Uint8List encode(Int16List pcm);

  /// Pushes [tuning] to the live encoder. Returns false if any CTL was
  /// rejected, leaving the encoder on whatever it had before — a rejected
  /// tuning is a reason to stop tuning, never a reason to stop encoding.
  bool applyTuning(OpusTuning tuning);

  /// Frees the native encoder and its buffers. Safe to call more than once.
  void destroy();
}

/// An Opus decoder that can also reconstruct a lost frame from the in-band FEC
/// copy carried by the frame after it.
abstract interface class ControlledOpusDecoder {
  /// Decodes one packet normally.
  ///
  /// Returns normalised samples in [-1, 1] as a `Float32List`, which is a
  /// `List<double>` — so it reaches the resampler and the jitter buffer with no
  /// conversion pass at all, where the previous path walked every sample to
  /// divide an int16 by 32768.
  List<double> decode(Uint8List packet);

  /// Reconstructs the frame *before* [packet] from the FEC copy embedded in it.
  ///
  /// [missingSamples] must be exactly the length of the lost frame — this is
  /// libopus's `frame_size` for a FEC decode, and getting it wrong is the whole
  /// reason the package's own FEC path fails.
  ///
  /// Never returns silence to signal failure: if the packet carries no FEC data
  /// (the sender budgeted no loss, or is an older build), libopus synthesises a
  /// concealment frame from the decoder's own state instead, which is the "PLC"
  /// half of the roadmap item and still far better than a hole.
  List<double> decodeFec(Uint8List packet, int missingSamples);

  /// Frees the native decoder and its buffer. Safe to call more than once.
  void destroy();
}
