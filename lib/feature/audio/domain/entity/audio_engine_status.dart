import 'package:equatable/equatable.dart';

/// Engine health as seen by consumers: whether the mic permission was
/// granted and whether the duplex engine is currently running.
class AudioEngineStatus extends Equatable {
  final bool hasPermission;
  final bool isStarted;

  const AudioEngineStatus({
    required this.hasPermission,
    required this.isStarted,
  });

  factory AudioEngineStatus.initial() =>
      const AudioEngineStatus(hasPermission: true, isStarted: false);

  @override
  List<Object?> get props => [hasPermission, isStarted];
}
