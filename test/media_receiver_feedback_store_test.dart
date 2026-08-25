import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';
import 'package:tark/feature/transfer/domain/service/media_receiver_feedback_store.dart';

void main() {
  const clean = MediaReceiverFeedback(
    queuedMs: 120,
    underruns: 0,
    outputStarvations: 0,
    trims: 0,
    overflowDrops: 0,
    staleDrops: 0,
    duplicateDrops: 0,
    resyncs: 0,
    concealedMs: 0,
  );

  const distressed = MediaReceiverFeedback(
    queuedMs: 390,
    underruns: 2,
    outputStarvations: 1,
    trims: 0,
    overflowDrops: 1,
    staleDrops: 3,
    duplicateDrops: 0,
    resyncs: 1,
    concealedMs: 40,
  );

  test('snapshot preserves missing peer as unconfirmed null', () {
    final store = MediaReceiverFeedbackStore();
    final now = DateTime.utc(2026, 8, 25, 19);
    store.observe('peer-a', clean, now);

    final snapshot = store.snapshot(['peer-a', 'peer-b'], now);

    expect(snapshot, [clean, null]);
  });

  test('latest feedback replaces older window for the same peer', () {
    final store = MediaReceiverFeedbackStore();
    final now = DateTime.utc(2026, 8, 25, 19);
    store.observe('peer-a', clean, now);
    store.observe('peer-a', distressed, now.add(const Duration(seconds: 1)));

    expect(store.snapshot(['peer-a'], now.add(const Duration(seconds: 1))), [
      distressed,
    ]);
  });

  test('stale feedback becomes unconfirmed instead of staying clean', () {
    final store = MediaReceiverFeedbackStore(
      staleAfter: const Duration(seconds: 8),
    );
    final now = DateTime.utc(2026, 8, 25, 19);
    store.observe('peer-a', clean, now);

    expect(store.snapshot(['peer-a'], now.add(const Duration(seconds: 8))), [
      clean,
    ]);
    expect(store.snapshot(['peer-a'], now.add(const Duration(seconds: 9))), [
      null,
    ]);
  });

  test('remove and reset discard old session evidence deterministically', () {
    final store = MediaReceiverFeedbackStore();
    final now = DateTime.utc(2026, 8, 25, 19);
    store.observe('peer-a', clean, now);
    store.observe('peer-b', distressed, now);

    store.removePeer('peer-a');
    expect(store.snapshot(['peer-a', 'peer-b'], now), [null, distressed]);

    store.reset();
    expect(store.snapshot(['peer-b'], now), [null]);
  });

  test('empty peer id cannot create session feedback state', () {
    final store = MediaReceiverFeedbackStore();
    final now = DateTime.utc(2026, 8, 25, 19);
    store.observe('', clean, now);

    expect(store.snapshot([''], now), [null]);
  });
}
