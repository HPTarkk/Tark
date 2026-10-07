import 'dart:typed_data';

/// Stateful sample-rate conversion owned by the platform realtime core.
///
/// Implementations preserve phase/history across arbitrary chunks. Call
/// [dispose] when a wire format is replaced so native state is released.
abstract interface class RealtimeResampler {
  Float64List process(List<double> samples);
  void reset();
  void dispose();
}

/// Stateful anti-alias filter owned by the platform realtime core.
abstract interface class RealtimeLowPass {
  Float64List process(List<double> samples);
  void reset();
  void dispose();
}


/// Stateful streaming spectral suppressor owned by the platform realtime core.
abstract interface class RealtimeSpectralSuppressor {
  double get strength;
  set strength(double value);
  Float64List process(List<double> samples);
  void reset();
  void dispose();
}
