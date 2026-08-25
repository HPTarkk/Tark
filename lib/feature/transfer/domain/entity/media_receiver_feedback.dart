/// Privacy-safe Shared Music receiver-health feedback carried by transport
/// control packets.
///
/// This is deliberately only counters/gauges. It contains no audio, sender
/// name, Room identity, network address, or transport credential. A null
/// feedback value means an older/unconfirmed peer; an all-zero value means the
/// receiver explicitly reported a clean window.
class MediaReceiverFeedback {
  const MediaReceiverFeedback({
    required this.queuedMs,
    required this.underruns,
    required this.outputStarvations,
    required this.trims,
    required this.overflowDrops,
    required this.staleDrops,
    required this.duplicateDrops,
    required this.resyncs,
    required this.concealedMs,
  });

  final int queuedMs;
  final int underruns;
  final int outputStarvations;
  final int trims;
  final int overflowDrops;
  final int staleDrops;
  final int duplicateDrops;
  final int resyncs;
  final int concealedMs;
}
