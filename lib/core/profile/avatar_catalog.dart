/// The predefined avatars a person can pick for their profile.
///
/// Only the small integer id is stored and sent to other phones, never the
/// picture, so every id below is permanent once shipped: a new avatar gets a
/// new id, and a retired one keeps its number unused. A phone on an older
/// version that meets an id it does not know draws [AvatarCatalog.unknown]
/// instead (see ProfileAvatar), which is what makes adding avatars later a
/// safe, one-sided change.
abstract final class AvatarCatalog {
  /// Every avatar this build knows, in picker order.
  static const all = <AvatarDef>[
    AvatarDef(1, 'assets/avatars/01-man.jpg'),
    AvatarDef(2, 'assets/avatars/02-woman.jpg'),
    AvatarDef(3, 'assets/avatars/03-rider.jpg'),
    AvatarDef(4, 'assets/avatars/04-woman-rider.jpg'),
    AvatarDef(5, 'assets/avatars/05-fox.jpg'),
    AvatarDef(6, 'assets/avatars/06-cat.jpg'),
    AvatarDef(7, 'assets/avatars/07-bear.jpg'),
    AvatarDef(8, 'assets/avatars/08-owl.jpg'),
    AvatarDef(9, 'assets/avatars/09-robot.jpg'),
    AvatarDef(10, 'assets/avatars/10-astronaut.jpg'),
    AvatarDef(11, 'assets/avatars/11-ninja.jpg'),
    AvatarDef(12, 'assets/avatars/12-alien.jpg'),
  ];

  /// Largest id a phone will accept from the wire or from storage. Keeps a
  /// corrupt or hostile value from being treated as a real (future) avatar.
  static const maxId = 255;

  static final _byId = {for (final a in all) a.id: a};

  /// The avatar for [id], or null when this build has no picture for it.
  static AvatarDef? byId(int? id) => id == null ? null : _byId[id];

  /// Whether [id] is shaped like an avatar id at all, known here or not.
  static bool isValidId(int? id) => id != null && id >= 1 && id <= maxId;

  /// A default for someone who has never picked one, e.g. a person who
  /// finished setup before avatars existed. Derived from the name so it is
  /// stable across launches and so a room of such people does not all show
  /// the same face; they can change it on the Profile page.
  static int defaultFor(String name) {
    var hash = 0;
    for (final unit in name.trim().toLowerCase().codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return all[hash % all.length].id;
  }
}

/// One predefined avatar: its permanent id and the bundled picture.
class AvatarDef {
  const AvatarDef(this.id, this.asset);

  final int id;
  final String asset;
}
