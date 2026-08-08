import 'dart:math' as math;

/// How much disk the on-device diagnostic log is allowed to occupy, and the
/// ladder of sizes a user may choose from.
///
/// The log is a ring, not an archive. Once the budget is spent the oldest
/// segment is deleted to make room for the newest line, so the answer to
/// "how big can this get?" is exactly [maxBytes] and never "it depends how
/// long the app ran". Everything in this file is pure arithmetic — no I/O —
/// so the rules can be tested without touching a filesystem.
abstract final class LogBudget {
  /// Floor. Below roughly this a single stack trace fills the whole log and
  /// the feature stops being able to answer the question it exists for.
  static const minBytes = 20 * 1024;

  /// Ceiling. Deliberately far below "as much as the phone has": a log the
  /// user cannot realistically send back is a log nobody ever reads, and the
  /// export has to survive being attached to a chat message.
  static const maxBytes = 100 * 1024 * 1024;

  /// Several days of ordinary use, and well under a megabyte once the export
  /// is compressed. Big enough that a bug reported the next morning is still
  /// on record; small enough that nobody notices the storage.
  static const defaultBytes = 8 * 1024 * 1024;

  /// The budget is spread over this many files.
  ///
  /// Rotation works by deleting the oldest whole file, so this is really a
  /// resolution knob: at eight segments, "make room" costs the oldest eighth
  /// of the log rather than the oldest half. More segments would be finer
  /// still, but every one of them is a `stat` on each flush and a file handle
  /// on each read.
  static const segments = 8;

  /// The sizes the picker offers, smallest first.
  ///
  /// A plain linear slider is useless across a 5000× range — the entire lower
  /// half of the scale would live in the first pixel — so the control snaps
  /// to this ladder instead. Every entry formats to a round number, which is
  /// the other half of why it exists: nobody wants to land on "37.4 MB".
  static const steps = <int>[
    20 * 1024,
    50 * 1024,
    100 * 1024,
    250 * 1024,
    500 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
    4 * 1024 * 1024,
    8 * 1024 * 1024,
    16 * 1024 * 1024,
    25 * 1024 * 1024,
    50 * 1024 * 1024,
    75 * 1024 * 1024,
    100 * 1024 * 1024,
  ];

  /// Forces any value — a stored preference from a future build, a hand-edited
  /// prefs file, a nonsense zero — inside the supported range.
  static int clamp(int bytes) {
    if (bytes < minBytes) return minBytes;
    if (bytes > maxBytes) return maxBytes;
    return bytes;
  }

  /// Size of one rotation segment for [budget].
  ///
  /// Kept strictly below the budget itself so that a full ring is always
  /// several files: the newest lines and the oldest ones are never in the
  /// same file, which is what lets rotation drop history without dropping
  /// the session that just went wrong.
  static int segmentBytes(int budget) =>
      math.max(1024, clamp(budget) ~/ segments);

  /// Index into [steps] of the entry closest to [bytes].
  ///
  /// Nearest in *ratio*, not in absolute difference: on a ladder that spans
  /// 20 KB to 100 MB, absolute distance would snap almost everything to the
  /// top two rungs.
  static int stepIndexFor(int bytes) {
    final value = clamp(bytes);
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < steps.length; i++) {
      final distance = (math.log(steps[i] / value)).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  /// `20 KB`, `8 MB`, `1.5 MB` — ASCII digits, for callers that localize them.
  ///
  /// One decimal at most: this number is read at a glance to decide whether
  /// the log is worth sending, and a third significant figure answers nothing.
  static String format(int bytes) {
    if (bytes >= 1024 * 1024) return '${_trim(bytes / (1024 * 1024))} MB';
    if (bytes >= 1024) return '${_trim(bytes / 1024)} KB';
    return '${math.max(0, bytes)} B';
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
}
