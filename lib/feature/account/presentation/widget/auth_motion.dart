import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../../core/account/auth_result.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/route_arrival.dart';
import '../../../../core/theme/app_colors.dart';

/// The one glyph that carries the account flow from screen to screen.
///
/// Every account screen stands on the same [StatusHero] at the same spot,
/// and Profile's account card opens the flow from a small glyph of its own.
/// Tagging all of them with one hero means that, as a screen slides in, its
/// glyph does not arrive with it: the glyph already on screen *stays* and
/// turns into the next one. Sign in becomes Create an account becomes the
/// code screen while the person keeps looking at one thing, and from Profile
/// the card's small mark grows into the screen's large one, the same way the
/// home chip grows into Profile.
///
/// Reduced motion turns the flight off; each screen arrives with its glyph
/// already in place, like every other transition then.
class AuthHero extends StatelessWidget {
  const AuthHero({
    required this.icon,
    required this.color,
    required this.look,
    required this.child,
    this.tag = AuthHero.flowTag,
    super.key,
  });

  /// Shared by Profile's signed-out card and every sign-in screen.
  static const flowTag = 'auth-hero';

  /// Shared by Profile's subscription card and the subscription screen. A
  /// tag of its own, so it can never meet the sign-in card's while the
  /// account card swaps between the two.
  static const subscriptionTag = 'auth-hero-subscription';

  final Object tag;
  final IconData icon;
  final Color color;
  final AuthHeroLook look;
  final Widget child;

  @override
  Widget build(BuildContext context) => HeroMode(
    enabled: !AppMotion.reduced(context),
    child: _TaggedHero(
      tag: tag,
      icon: icon,
      color: color,
      look: look,
      flightShuttleBuilder: _flight,
      child: child,
    ),
  );

  static Widget _flight(
    BuildContext context,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromContext,
    BuildContext toContext,
  ) {
    final from = fromContext.widget as _TaggedHero;
    final to = toContext.widget as _TaggedHero;
    // The flight's clock always reads 0 on the screen underneath and 1 on
    // the one on top, whichever way it is going; ends are named that way.
    final push = direction == HeroFlightDirection.push;
    return _AuthHeroFlight(
      key: const ValueKey('auth-hero-flight'),
      animation: animation,
      under: push ? from : to,
      over: push ? to : from,
    );
  }
}

/// How one end of an [AuthHero] flight is drawn, so the flight can grow one
/// into the other.
@immutable
class AuthHeroLook {
  const AuthHeroLook({
    required this.coreFraction,
    required this.iconSize,
    required this.fill,
    required this.ring,
  });

  /// The [StatusHero] at the top of every account screen: a card-coloured
  /// core with a coloured ring, in a box that leaves room for its halo.
  factory AuthHeroLook.status(double coreFraction) => AuthHeroLook(
    coreFraction: coreFraction,
    iconSize: 34,
    fill: AppColors.card,
    ring: 1,
  );

  /// A small tinted disc, like the account card's.
  factory AuthHeroLook.badge(Color color, {double iconSize = 20}) =>
      AuthHeroLook(
        coreFraction: 1,
        iconSize: iconSize,
        fill: color.withValues(alpha: 0.16),
        ring: 0,
      );

  /// How much of the hero's box the disc fills.
  final double coreFraction;
  final double iconSize;
  final Color fill;

  /// How strong the coloured ring is, 0 to 1.
  final double ring;
}

class _TaggedHero extends Hero {
  const _TaggedHero({
    required super.tag,
    required this.icon,
    required this.color,
    required this.look,
    super.flightShuttleBuilder,
    required super.child,
  });

  final IconData icon;
  final Color color;
  final AuthHeroLook look;
}

/// The glyph in flight: one disc that grows, takes on the next screen's
/// surface and colour, and hands its icon over to the next one — the old
/// icon sinks and shrinks as the new one grows into its place.
class _AuthHeroFlight extends StatelessWidget {
  const _AuthHeroFlight({
    required this.animation,
    required this.under,
    required this.over,
    super.key,
  });

  final Animation<double> animation;
  final _TaggedHero under;
  final _TaggedHero over;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = AppMotion.easeOut.transform(animation.value.clamp(0.0, 1.0));
      final a = under.look;
      final b = over.look;
      final color = Color.lerp(under.color, over.color, t)!;
      final ring = lerpDouble(a.ring, b.ring, t)!;
      final iconSize = lerpDouble(a.iconSize, b.iconSize, t)!;
      final sameIcon = under.icon == over.icon;
      return LayoutBuilder(
        builder: (context, box) {
          final side =
              box.biggest.shortestSide *
              lerpDouble(a.coreFraction, b.coreFraction, t)!;
          // The swap happens in the middle of the flight, where the disc is
          // moving fastest and the eye is following it rather than its mark.
          final swap = ((t - 0.2) / 0.6).clamp(0.0, 1.0);
          return Center(
            child: Container(
              width: side,
              height: side,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(a.fill, b.fill, t),
                border: Border.all(
                  color: color.withValues(alpha: 0.85 * ring),
                  width: 2 * ring,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.26 * ring),
                    blurRadius: 24 * ring,
                    spreadRadius: ring,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: sameIcon
                  ? Icon(over.icon, color: color, size: iconSize)
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        Opacity(
                          opacity: 1 - swap,
                          child: Transform.scale(
                            scale: 1 - 0.4 * swap,
                            child: Icon(
                              under.icon,
                              color: color,
                              size: iconSize,
                            ),
                          ),
                        ),
                        Opacity(
                          opacity: swap,
                          child: Transform.scale(
                            scale:
                                0.6 + 0.4 * Curves.easeOutBack.transform(swap),
                            child: Icon(
                              over.icon,
                              color: color,
                              size: iconSize,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      );
    },
  );
}

/// The fields an account form asks for, so a refusal can point at the one
/// it is about.
enum AuthField { name, email, password, newPassword }

/// Which of [fields] a refusal is about, given what is typed in each, so
/// that field alone shakes. Null when the refusal is about no one field
/// (the connection, a locked account): then only the screen's hero shakes.
///
/// [fields] is in screen order: "something is missing" points at the first
/// empty one.
AuthField? authErrorField(AuthError? error, List<(AuthField, String)> fields) {
  if (error == null) return null;
  final asked = {for (final (field, _) in fields) field};
  AuthField? ifAsked(AuthField field) => asked.contains(field) ? field : null;
  final password = asked.contains(AuthField.newPassword)
      ? AuthField.newPassword
      : ifAsked(AuthField.password);
  switch (error.kind) {
    case AuthErrorKind.incomplete:
      for (final (field, text) in fields) {
        if (text.trim().isEmpty) return field;
      }
      return null;
    case AuthErrorKind.emailInvalid || AuthErrorKind.emailAlreadyRegistered:
      return ifAsked(AuthField.email);
    case AuthErrorKind.invalidCredentials:
      return ifAsked(AuthField.password);
    case AuthErrorKind.passwordTooShort ||
        AuthErrorKind.passwordTooLong ||
        AuthErrorKind.passwordTooCommon ||
        AuthErrorKind.passwordMatchesEmail ||
        AuthErrorKind.passwordInvalid ||
        AuthErrorKind.passwordUnchanged:
      return password;
    case AuthErrorKind.invalidRequest:
      return switch (error.field) {
        'email' => ifAsked(AuthField.email),
        'name' => ifAsked(AuthField.name),
        'password' => password,
        _ => null,
      };
    default:
      return null;
  }
}

/// Shakes [child] sideways once each time [trigger] changes to a new
/// non-null value: the field a refusal is about, refusing like a lock
/// refuses a wrong key. The same swing as the [StatusHero]'s, smaller.
/// Reduced motion holds it still.
class AuthShake extends StatefulWidget {
  const AuthShake({required this.trigger, required this.child, super.key});

  final Object? trigger;
  final Widget child;

  @override
  State<AuthShake> createState() => _AuthShakeState();
}

class _AuthShakeState extends State<AuthShake>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: AppMotion.entrance + AppMotion.press,
  );

  @override
  void didUpdateWidget(AuthShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    final trigger = widget.trigger;
    if (trigger != null &&
        trigger != oldWidget.trigger &&
        !AppMotion.reduced(context)) {
      unawaited(_shake.forward(from: 0));
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _shake,
    child: widget.child,
    builder: (context, child) {
      final t = _shake.value;
      final dx = math.sin(t * math.pi * 6) * 6 * (1 - t);
      return Transform.translate(offset: Offset(dx, 0), child: child);
    },
  );
}

/// A chevron that leans twice towards where it leads once its screen has
/// arrived: a quiet "this way" on a card people might otherwise read past,
/// that then rests rather than nagging. Mirrored in Persian. Under reduced
/// motion it holds still.
class NudgingChevron extends StatefulWidget {
  const NudgingChevron({
    required this.color,
    required this.background,
    this.size = 30,
    super.key,
  });

  final Color color;
  final Color background;
  final double size;

  @override
  State<NudgingChevron> createState() => _NudgingChevronState();
}

class _NudgingChevronState extends State<NudgingChevron>
    with SingleTickerProviderStateMixin, RouteArrival {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: AppMotion.successBeat + AppMotion.sheet,
  );

  @override
  void onRouteArrived() {
    if (!AppMotion.reduced(context)) unawaited(_loop.forward());
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sign = AppMotion.forwardSign(Directionality.of(context));
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.background,
      ),
      child: AnimatedBuilder(
        animation: _loop,
        builder: (context, child) {
          // Two leans, the second softer, then rest.
          final p = _loop.value;
          final dx = math.sin(p * math.pi * 2).abs() * 3.5 * (1 - p);
          return Transform.translate(
            offset: Offset(dx * sign, 0),
            child: child,
          );
        },
        child: Icon(
          Icons.chevron_right_rounded,
          color: widget.color,
          size: widget.size * 2 / 3,
        ),
      ),
    );
  }
}
