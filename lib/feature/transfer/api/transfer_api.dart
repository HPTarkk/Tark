/// Public surface of the transfer feature.
///
/// Everything outside lib/feature/transfer must import this barrel (or
/// core/) — never the feature's internal domain/data/presentation files.
library;

export '../data/codec/opus_audio_codec.dart' show OpusAudioCodec;
export '../data/webrtc/sdp_codec.dart';
export '../domain/entity/guest_link_state.dart';
export '../domain/entity/transfer_mode.dart';
export '../domain/entity/waki_packet.dart';
export '../domain/repository/guest_link_controller.dart';
export '../domain/repository/transfer_repository.dart';
export '../domain/service/transfer_mode_store.dart';
export '../presentation/page/bluetooth_connect_page.dart';
export '../presentation/page/guest_link_page.dart';
export '../presentation/page/hotspot_bridge_page.dart';
