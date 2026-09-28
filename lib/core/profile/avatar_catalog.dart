/// The predefined avatars a person can pick for their profile.
///
/// Only the small integer id is stored and sent to other phones, never the
/// picture, so every id below is permanent once shipped: a new avatar gets a
/// new id, and a retired one keeps its number unused. A phone on an older
/// version that meets an id it does not know draws a "newer avatar" face
/// instead (see AppAvatar), which is what makes adding avatars later a
/// safe, one-sided change.
abstract final class AvatarCatalog {
  /// The Tarkk mascot: the app's own character, and everyone's avatar until
  /// they pick another one.
  static const defaultId = 13;

  /// Every avatar this build knows, in picker order: the mascot first, then
  /// the unisex characters, then the rest. Picker order is free to change;
  /// ids are not.
  static const all = <AvatarDef>[
    AvatarDef(13, 'assets/avatars/13-tarkk.webp'),
    AvatarDef(14, 'assets/avatars/14-helmet-rider.webp'),
    AvatarDef(15, 'assets/avatars/15-hoodie.webp'),
    AvatarDef(16, 'assets/avatars/16-climber.webp'),
    AvatarDef(17, 'assets/avatars/17-pilot.webp'),
    AvatarDef(18, 'assets/avatars/18-diver.webp'),
    AvatarDef(19, 'assets/avatars/19-gamer.webp'),
    AvatarDef(1, 'assets/avatars/01-man.webp'),
    AvatarDef(2, 'assets/avatars/02-woman.webp'),
    AvatarDef(3, 'assets/avatars/03-rider.webp'),
    AvatarDef(4, 'assets/avatars/04-woman-rider.webp'),
    AvatarDef(5, 'assets/avatars/05-fox.webp'),
    AvatarDef(6, 'assets/avatars/06-cat.webp'),
    AvatarDef(7, 'assets/avatars/07-bear.webp'),
    AvatarDef(8, 'assets/avatars/08-owl.webp'),
    AvatarDef(9, 'assets/avatars/09-robot.webp'),
    AvatarDef(10, 'assets/avatars/10-astronaut.webp'),
    AvatarDef(11, 'assets/avatars/11-ninja.webp'),
    AvatarDef(12, 'assets/avatars/12-alien.webp'),
  ];

  /// Largest id a phone will accept from the wire or from storage. Keeps a
  /// corrupt or hostile value from being treated as a real (future) avatar.
  static const maxId = 255;

  static final _byId = {for (final a in all) a.id: a};

  /// The avatar for [id], or null when this build has no picture for it.
  static AvatarDef? byId(int? id) => id == null ? null : _byId[id];

  /// Whether [id] is shaped like an avatar id at all, known here or not.
  static bool isValidId(int? id) => id != null && id >= 1 && id <= maxId;
}

/// One predefined avatar: its permanent id and the bundled picture.
class AvatarDef {
  const AvatarDef(this.id, this.asset);

  final int id;
  final String asset;
}
