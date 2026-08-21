import 'dart:io';

import '../../../../core/utils/local_network.dart';
import '../../../transfer/domain/entity/channel_intent.dart';
import '../../../transfer/domain/entity/transfer_mode.dart';
import '../../../transfer/domain/service/transport_advisor.dart';

/// Builds the [ChannelPlan] Preflight needs when a transport was already
/// chosen by hand rather than derived from a live [LandingCubit] — the
/// onboarding launch beat, and a `SilentPreflightGuard` page that is already
/// running under a known [TransferMode]. `LandingState.conditions` computes
/// the same [LinkConditions] fields (`hasWifi` from a live local address,
/// the rest from platform constants); this is that same logic for callers
/// with no `LandingCubit` instance to ask.
Future<ChannelPlan> pinnedPlanFor(
  TransferMode mode, {
  ChannelIntent intent = ChannelIntent.create,
}) async => TransportAdvisor.plan(
  intent,
  LinkConditions(
    hasWifi: await LocalNetwork.ipv4Address() != null,
    // Only Android can raise a local-only access point.
    canHostHotspot: Platform.isAndroid,
    // Both phone platforms can be told to associate with a scanned network.
    canJoinHotspot: Platform.isAndroid || Platform.isIOS,
    // Android runs Classic RFCOMM + BLE, iOS runs BLE; desktop and web have
    // no Bluetooth transport at all.
    bluetoothSupported: Platform.isAndroid || Platform.isIOS,
    pinned: mode,
  ),
);
