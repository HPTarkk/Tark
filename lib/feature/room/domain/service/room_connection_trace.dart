import '../../../../core/utils/logger.dart';

/// Credential-free correlation for one durable Room across device logs.
///
/// The raw Room id never enters diagnostics. A small stable FNV-1a digest lets
/// two exported log files be paired without leaking SSIDs, IP addresses,
/// Bluetooth addresses, display names, or the durable Room identifier itself.
abstract final class RoomConnectionTrace {
  const RoomConnectionTrace._();

  static String correlationId(String roomId) {
    var hash = 0x811c9dc5;
    for (final unit in roomId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'rc-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  static void stage({
    required String roomId,
    required int attempt,
    required String stage,
    int? attachmentGeneration,
  }) {
    final correlation = correlationId(roomId);
    final attachment = attachmentGeneration == null
        ? ''
        : ' attachment=$attachmentGeneration';
    Logger.diagnostic(
      'room: readiness corr=$correlation attempt=$attempt '
      'stage=$stage$attachment',
    );
  }
}
