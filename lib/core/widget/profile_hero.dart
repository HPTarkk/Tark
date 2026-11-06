import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import 'app_avatar.dart';

/// The shared elements that carry the person's identity from Home's profile
/// chip into the Profile page, so opening Profile reads as the chip growing
/// into the page instead of a new screen sliding over it.
///
/// Two pieces fly: the face, which grows from the chip's small avatar into the
/// large one, and the name, which grows into the editable field and picks up
/// the field's surface on the way. Both go back the same way on close.
abstract final class ProfileHero {
  static const avatarTag = 'profile-avatar';
  static const nameTag = 'profile-name';

  /// The face. Redrawn at the in-flight size on every frame rather than
  /// scaled, so the initial letter stays crisp at every size. On Profile the
  /// face sits in a glowing ring; the ring grows out of the avatar in flight
  /// instead of waiting, empty, for the face to arrive.
  static Widget avatar({
    required String name,
    required int? avatarId,
    required Widget child,
  }) => _still(
    _ProfileHero(
      tag: avatarTag,
      name: name,
      avatarId: avatarId,
      flightShuttleBuilder: (_, animation, _, from, to) {
        final ends = _ends(from, to);
        return _AvatarFlight(
          name: ends.name,
          avatarId: ends.avatarId,
          animation: animation,
        );
      },
      child: child,
    ),
  );

  /// The name. [child] is the widget drawn when the name is not flying: the
  /// chip's label on Home, the editable field on Profile.
  static Widget name({required String name, required Widget child}) => _still(
    _ProfileHero(
      tag: nameTag,
      name: name,
      flightShuttleBuilder: (_, animation, _, from, to) =>
          _NameFlight(name: _ends(from, to).name, animation: animation),
      child: child,
    ),
  );

  /// Under reduced motion nothing flies: the page simply fades in with its
  /// face and name already in place, like every other transition then.
  static Widget _still(Widget hero) => Builder(
    builder: (context) =>
        HeroMode(enabled: !AppMotion.reduced(context), child: hero),
  );

  /// Profile reads the name and face asynchronously, so on its first frame
  /// its side may still be blank. Whichever end knows them is used.
  static ({String name, int? avatarId}) _ends(
    BuildContext from,
    BuildContext to,
  ) {
    final a = from.widget as _ProfileHero;
    final b = to.widget as _ProfileHero;
    final known = b.name.trim().isNotEmpty ? b : a;
    return (name: known.name, avatarId: known.avatarId ?? a.avatarId);
  }
}

/// A [Hero] that also carries what the flight needs to draw.
class _ProfileHero extends Hero {
  const _ProfileHero({
    required super.tag,
    required this.name,
    this.avatarId,
    super.flightShuttleBuilder,
    required super.child,
  });

  final String name;
  final int? avatarId;
}

/// The face in flight. Its ring, glow and the gap inside the ring are only
/// part of Profile's face, so they fade and grow in as it lands. The numbers
/// match Profile's face: 4 padding inside a 2 border.
class _AvatarFlight extends StatelessWidget {
  const _AvatarFlight({
    required this.name,
    required this.avatarId,
    required this.animation,
  });

  final String name;
  final int? avatarId;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = animation.value.clamp(0.0, 1.0);
      final amber = AppColors.amber;
      return LayoutBuilder(
        builder: (_, box) {
          final side = box.biggest.shortestSide;
          final inset = 6 * t;
          return Center(
            child: Container(
              width: side,
              height: side,
              padding: EdgeInsets.all(inset),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: amber.withValues(alpha: 0.6 * t),
                  width: 2 * t,
                ),
                boxShadow: [
                  BoxShadow(
                    color: amber.withValues(alpha: 0.22 * t),
                    blurRadius: 20 * t,
                    spreadRadius: t,
                  ),
                ],
              ),
              child: AppAvatar(
                name: name,
                avatarId: avatarId,
                size: side - 2 * inset,
              ),
            ),
          );
        },
      );
    },
  );
}

/// The name in flight: plain chip text at one end, the profile's name field
/// at the other. The field's surface, border and padding fade in around the
/// text as it grows, so the label visibly turns into the field.
class _NameFlight extends StatelessWidget {
  const _NameFlight({required this.name, required this.animation});

  final String name;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // The route's animation: 0 at Home, 1 at Profile, in both
        // directions.
        final t = Curves.easeInOut.transform(animation.value);
        final field = t.clamp(0.0, 1.0);
        return Container(
          alignment: AlignmentDirectional.centerStart,
          padding: EdgeInsetsDirectional.lerp(
            EdgeInsetsDirectional.zero,
            const EdgeInsetsDirectional.fromSTEB(14, 0, 8, 0),
            field,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: field),
            borderRadius: BorderRadius.circular(14 * field),
            border: Border.all(
              color: AppColors.border.withValues(alpha: field),
            ),
          ),
          child: Text(
            name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13.5 + (17 - 13.5) * field,
              fontWeight: FontWeight.lerp(
                FontWeight.w700,
                FontWeight.w800,
                field,
              ),
            ),
          ),
        );
      },
    ),
  );
}
