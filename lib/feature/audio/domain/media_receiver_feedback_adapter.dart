import '../../transfer/domain/entity/media_receiver_feedback.dart';
import 'media_adaptation_controller.dart';
import 'media_receive_buffer.dart';

/// Bridges transport-level receiver feedback into the Shared Music adaptation
/// policy without leaking transport details into the audio domain.
///
/// A null feedback payload is deliberately represented as an unconfirmed
/// receiver rather than a clean receiver. This keeps mixed-version rooms and
/// peers that have not yet returned health evidence on the conservative tier.
abstract final class MediaReceiverFeedbackAdapter {
  static MediaReceiverWindow toWindow(MediaReceiverFeedback? feedback) {
    if (feedback == null) {
      return const MediaReceiverWindow(
        health: MediaReceiveHealth(
          queuedMs: 0,
          underruns: 0,
          outputStarvations: 0,
          trims: 0,
          overflowDrops: 0,
          staleDrops: 0,
          duplicateDrops: 0,
          resyncs: 0,
          concealedMs: 0,
        ),
        bidirectionalConfirmed: false,
      );
    }

    return MediaReceiverWindow(
      health: MediaReceiveHealth(
        queuedMs: feedback.queuedMs,
        underruns: feedback.underruns,
        outputStarvations: feedback.outputStarvations,
        trims: feedback.trims,
        overflowDrops: feedback.overflowDrops,
        staleDrops: feedback.staleDrops,
        duplicateDrops: feedback.duplicateDrops,
        resyncs: feedback.resyncs,
        concealedMs: feedback.concealedMs,
      ),
      bidirectionalConfirmed: true,
    );
  }

  /// Converts one window per current peer. Missing feedback for any peer is
  /// retained as unconfirmed evidence; it is never filtered out as if that
  /// receiver were healthy.
  static List<MediaReceiverWindow> toWindows(
    Iterable<MediaReceiverFeedback?> feedbackByPeer,
  ) => feedbackByPeer.map(toWindow).toList(growable: false);
}
