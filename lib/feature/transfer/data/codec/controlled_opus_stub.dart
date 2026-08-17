import 'controlled_opus.dart';

/// Web (and any build without dart:ffi): there is no native pointer to bind
/// against — `opus_flutter` hands `opus_dart` a web_ffi library, not a
/// `DynamicLibrary` — so neither controlled codec is ever available here.
///
/// Returning null is the whole implementation. The caller falls back to
/// `opus_dart`'s `SimpleOpusEncoder`/`SimpleOpusDecoder`, so the guest web
/// build encodes and decodes exactly as it always has, just without FEC. That
/// is the right trade for it: the guest link is a WebRTC data channel, not a
/// lossy hotspot between two motorcycles.
ControlledOpusEncoder? tryCreateControlledOpusEncoder({
  required Object? library,
  required int sampleRate,
  required int channels,
  required int application,
}) => null;

ControlledOpusDecoder? tryCreateControlledOpusDecoder({
  required Object? library,
  required int sampleRate,
  required int channels,
}) => null;
