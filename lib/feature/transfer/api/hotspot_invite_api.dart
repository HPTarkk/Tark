/// Narrow public contract used by the Room invite surface.
///
/// Hotspot credentials are ephemeral transport state. Keeping this surface
/// separate from the broad transfer barrel prevents unrelated consumers from
/// acquiring duplicate imports while preserving the feature boundary.
library;

export '../domain/entity/hotspot_credentials.dart' show HotspotCredentials;
export '../domain/service/hotspot_link_keeper.dart'
    show HotspotLinkKeeper, HotspotLinkState;
