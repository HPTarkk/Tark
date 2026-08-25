import '../../../audio/domain/media_adaptation_controller.dart';
import '../../../audio/domain/media_receiver_feedback_adapter.dart';
import '../entity/media_receiver_feedback.dart';
import 'media_receiver_feedback_store.dart';

/// Session-scoped composition root for receiver-driven Shared Music adaptation.
///
/// Transport code feeds decoded per-peer feedback into [observePeer], then asks
/// [evaluate] for the sender decision. Missing and stale peers stay represented
/// as unconfirmed evidence via [MediaReceiverFeedbackStore], so a mixed-version
/// or recovering room cannot accidentally promote media quality.
///
/// This runtime deliberately owns no socket, timer, codec or Room membership.
/// Callers provide the current peer ids and elapsed window; [reset] is invoked
/// when the transport/session generation changes.
class MediaReceiverAdaptationRuntime {
  MediaReceiverAdaptationRuntime()
    : store = MediaReceiverFeedbackStore(),
      controller = MediaAdaptationController();

  MediaReceiverAdaptationRuntime.withDependencies({
    required this.store,
    required this.controller,
  });

  final MediaReceiverFeedbackStore store;
  final MediaAdaptationController controller;

  void observePeer(
    String peerId,
    MediaReceiverFeedback feedback,
    DateTime now,
  ) {
    store.observe(peerId, feedback, now);
  }

  void removePeer(String peerId) {
    store.removePeer(peerId);
  }

  MediaAdaptationDecision evaluate({
    required Iterable<String> peerIds,
    required DateTime now,
    required int elapsedMs,
    bool voiceImpaired = false,
  }) {
    final feedback = store.snapshot(peerIds, now);
    final windows = MediaReceiverFeedbackAdapter.toWindows(feedback);
    return controller.observe(
      receivers: windows,
      elapsedMs: elapsedMs,
      voiceImpaired: voiceImpaired,
    );
  }

  void reset() {
    store.reset();
    controller.reset();
  }
}
