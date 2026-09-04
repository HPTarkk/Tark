/// Narrow public contract used by the Room invite surface.
///
/// Hotspot credentials are ephemeral transport state. Keeping this surface
/// separate from the broad transfer barrel prevents unrelated consumers from
/// acquiring duplicate imports while preserving the feature boundary.
library;

// [ScannedCode] rides along because the Room's own scanner has to be able to
// recognise a code it cannot use: the host shows a network QR on one screen
// and a Room invite on another, and telling a rider their invite is expired
// when they are holding a perfectly good hotspot code is the worst answer
// available. Recognising it is not acting on it — the bridge still owns the
// join.
export '../domain/entity/hotspot_credentials.dart'
    show HotspotCredentials, ScannedCode;
export '../domain/service/hotspot_link_keeper.dart'
    show HotspotLinkKeeper, HotspotLinkState;
