/// Public surface of the transfer feature.
///
/// Everything outside lib/feature/transfer must import this barrel (or
/// core/) — never the feature's internal domain/data/presentation files.
library;

export 'pre_live_hotspot_bootstrap.dart';
export '../data/capability/transport_capability_reader.dart';
export '../data/codec/opus_audio_codec.dart' show OpusAudioCodec;
export '../data/webrtc/ice_config.dart';
export '../data/webrtc/sdp_codec.dart';
export '../domain/entity/audio_profile.dart';
export '../domain/entity/connection_health.dart';
export '../domain/entity/guest_link_state.dart';
export '../domain/entity/live_link.dart';
export '../domain/entity/channel_intent.dart';
export '../domain/entity/session_role.dart';
export '../domain/entity/transfer_mode.dart';
export '../domain/entity/transfer_mode_analytics.dart';
export '../domain/entity/transport_capability_advertisement.dart';
export '../domain/entity/transport_capability_observation.dart';
export '../domain/entity/transport_route_proof_observation.dart';
export '../domain/entity/transport_stats.dart';
export '../domain/entity/waki_packet.dart';
export '../domain/entity/wifi_hotspot_segment.dart';
export '../domain/repository/guest_link_controller.dart';
export '../domain/repository/transfer_repository.dart';
export '../domain/entity/carrier_handover_observation.dart';
export '../domain/repository/carrier_handover_exchange.dart';
export '../domain/repository/transport_capability_observation_source.dart';
// This exposes carrier-observed proof exchange only; Room remains the authority.
export '../domain/repository/transport_route_proof_exchange.dart';
// Exported for Room failover composition and channel recovery actions. These
// interfaces expose temporary transport control only; Room identity must never
// be derived from hotspot credentials or network metadata.
export '../domain/service/hotspot_control.dart' show HotspotHost, HotspotJoiner;
export '../domain/service/hotspot_link_keeper.dart' show HotspotLinkKeeper;
// Create/one-scan Room entry stamps only a temporary bootstrap-side hint here.
// It is deliberately session-scoped and is not Room ownership or invite
// authority; the live deterministic planner/failover machinery remains the
// authority once peers can exchange verified capability evidence.
export '../domain/service/session_role_store.dart' show SessionRoleStore;
// The channel screen grades its own link: the two inputs the transport cannot
// know about (whether peers confirm they hear us, and whether the roster is
// empty) live in the cubit, so the grading happens there rather than here.
// Where a device goes to get onto a link with the people it is trying to
// reach — asked by the Room entry and by the channel's empty members card.
export '../domain/service/connect_route.dart';
export '../domain/service/link_quality.dart';
// Asked before a channel opens, by whatever is about to open one. Reading it
// starts nothing: see LiveLinkProbe.
export '../domain/service/live_link_probe.dart';
export '../domain/service/transfer_mode_store.dart';
// The landing page's Create/Join actions resolve their route through this;
// it is pure and holds no state, so it is exported rather than injected.
export '../domain/service/transport_advisor.dart';
export '../presentation/page/bluetooth_connect_page.dart';
export '../presentation/page/guest_link_page.dart';
export '../presentation/page/wifi_hotspot_page.dart';
