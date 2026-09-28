import 'package:flutter/material.dart';

import '../profile/avatar_catalog.dart';
import '../theme/app_colors.dart';

/// Shared avatar widget: the person's picked avatar, or their name's
/// initial in an amber circle when there is none.
///
/// Amber border when [isActive], grey border when inactive.
///
/// [avatarId] decides the face:
/// - an id this build knows draws that picture;
/// - a well-formed id it does not know (picked on a newer version) draws a
///   dedicated "new avatar" face rather than someone else's picture;
/// - null (never picked, or a phone too old to send one) keeps the initial.
class AppAvatar extends StatelessWidget {
  final String name;
  final int? avatarId;
  final bool isActive;
  final double size;

  const AppAvatar({
    super.key,
    required this.name,
    this.avatarId,
    this.isActive = true,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final pictured = AvatarPicture.shows(avatarId);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pictured ? null : AppColors.amber.withAlpha(30),
        border: Border.all(
          color: isActive ? AppColors.amber.withAlpha(180) : AppColors.border,
          width: 1.5,
        ),
        boxShadow: isActive
            ? [BoxShadow(color: AppColors.amber.withAlpha(60), blurRadius: 12)]
            : null,
      ),
      child: pictured
          ? AvatarPicture(
              avatarId: avatarId!,
              size: size,
              fallback: _Initial(name: name, size: size),
            )
          : _Initial(name: name, size: size),
    );
  }
}

/// Just the round picture for an avatar id, with no frame: the bundled image
/// for an id this build knows, or the "newer avatar" face for a well-formed
/// id it does not. Callers check [shows] first and draw their own fallback
/// (an initial) when it is false.
class AvatarPicture extends StatelessWidget {
  const AvatarPicture({
    super.key,
    required this.avatarId,
    required this.size,
    this.fallback,
  });

  final int avatarId;
  final double size;

  /// Drawn if the bundled image fails to load, so a missing asset never
  /// takes a row down with it.
  final Widget? fallback;

  /// Whether [id] gets a picture at all, known or not.
  static bool shows(int? id) => AvatarCatalog.isValidId(id);

  @override
  Widget build(BuildContext context) {
    final def = AvatarCatalog.byId(avatarId);
    if (def == null) return _UnknownAvatar(size: size);
    return ClipOval(
      child: Image.asset(
        def.asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => fallback ?? SizedBox.square(dimension: size),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return Center(
      child: Text(
        initial,
        style: TextStyle(
          color: AppColors.amber,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// The face for an avatar id from a newer version of the app: the avatar
/// set's orange disc with a sparkle, so it reads as "a picture this phone
/// hasn't got yet" rather than as a broken image or someone else's face.
class _UnknownAvatar extends StatelessWidget {
  const _UnknownAvatar({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('unknown-avatar'),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFF5853F),
      ),
      child: Center(
        child: Icon(
          Icons.auto_awesome_rounded,
          color: Colors.white,
          size: size * 0.5,
        ),
      ),
    );
  }
}
