/// Narrow public contract used by the Room invite surface.
///
/// Hotspot credentials and host role are ephemeral transport state. Keeping
/// this surface separate from the broad transfer barrel prevents unrelated
/// consumers from acquiring duplicate imports while still preserving the
/// feature boundary for Room presentation.
library;

export '../domain/entity/hotspot_credentials.dart' show HotspotCredentials;
export '../domain/entity/session_role.dart' show SessionRole;
export '../domain/repository/transfer_repository.dart'
    show TransferRepository;
export '../domain/service/hotspot_link_keeper.dart'
    show HotspotLinkKeeper, HotspotLinkState;
