import '../motion/continuity_route.dart';
import 'connection_journey.dart';

/// What a [ConnectionJourney] was showing when its screen handed the link on
/// to the next one — the invite scanner opening the channel's entry, say.
///
/// A [ContinuityHandoff], so the destination dissolves in over the scanner
/// instead of sliding in as a new page, and it carries enough for that
/// destination to draw the *same* scene from its very first frame. Without it
/// the entry had nothing to draw until it had read the Room back from
/// storage, and the person watched the journey cut to a blank page and back
/// halfway through connecting (2026-10-12 report).
class JourneyCarryOver extends ContinuityHandoff {
  const JourneyCarryOver({required this.link, this.caption});

  final JourneyLink link;

  /// The small caps over the scene, usually the Room's name.
  final String? caption;
}
