import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/widget/link_established.dart';
import '../../../preflight/presentation/widget/silent_preflight_guard.dart';
import '../../domain/entity/channel_intent.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';
import '../manager/wifi_hotspot_cubit.dart';
import '../widget/hotspot_host_flow.dart';
import '../widget/hotspot_join_flow.dart';
import '../widget/hotspot_role_picker.dart';
import '../widget/hotspot_segmented_control.dart';
import '../widget/hotspot_shared_widgets.dart';
import '../widget/hotspot_wifi_only_flow.dart';

/// Whether a bridge update is enough to leave transport setup and enter the
/// channel.
///
/// A generic/manual bridge still waits until an actual peer packet is heard.
/// The Room one-scan handoff is different: its membership was persisted before
/// this page opened, and [JoinPhase.joined] is emitted only *after* Android has
/// associated with the exact scanned network and bound the process to it. At
/// that point waiting for a Waki packet deadlocks the flow because Room live
/// publishers do not start until the Room route is allowed to open. Entering
/// then lets the live binding exchange signed capability/presence evidence and
/// confirm the pending seat without weakening any Room authorization check.
bool shouldEnterChannelAfterBridgeUpdate({
  required bool roomHandoff,
  required HotspotBridgeState state,
}) =>
    state.peerConnected ||
    (roomHandoff && state.joinPhase == JoinPhase.joined);

/// Combined WiFi / Hotspot entry point (item 9 merges the two mode-picker
/// tiles into one page):
///
///  * **Wi-Fi segment**: both devices already share a network — nothing to
///    set up, just enter the channel.
///  * **Hotspot segment**: **Android** (host) creates a local-only Wi-Fi
///    hotspot and shows a Wi-Fi QR + credentials for the iPhone to join;
///    **iOS** (join) scans the Android host's Wi-Fi QR and joins that
///    network. Either way, once a peer is heard (or the user taps through)
///    it enters the ordinary Wi-Fi channel.
class WifiHotspotPage extends StatefulWidget {
  const WifiHotspotPage._({required this.initialSegment, this.handedCode});

  final WifiHotspotSegment initialSegment;

  /// A payload somebody else's scanner already read, handed over instead of
  /// asking for it again.
  ///
  /// The Room one-scan page uses this after it has already persisted durable
  /// membership and the same QR also carries hotspot credentials. A legacy
  /// network-only scan can use the seam too; only a payload that actually has
  /// a `TARKROOM1` extension gets the invisible Room-handoff behaviour below.
  /// The camera has already been held up to either code once, so opening it a
  /// second time on arrival would be the app asking for something it holds.
  final String? handedCode;

  /// [intent] carries a side the user has already chosen on the landing page,
  /// so the bridge does not open by asking "are you the host?" one screen
  /// after they answered exactly that. Null when the page is reached without
  /// an intent — the Settings row, quick access, the "not on the same
  /// network?" way out — and then the role picker does its original job.
  ///
  /// Applied through [WifiHotspotCubit.chooseRole], not by pre-seeding state,
  /// so a preselected host still takes the side-exclusivity teardown and the
  /// role-store write that every other path takes. iOS is left alone: the
  /// cubit already pins it to joining, and it cannot host whatever the user
  /// tapped.
  static Widget buildPage({
    WifiHotspotSegment? initialSegment,
    ChannelIntent? intent,
    String? handedCode,
  }) => BlocProvider<WifiHotspotCubit>(
    create: (_) {
      final cubit = GetIt.instance<WifiHotspotCubit>();
      final segment = initialSegment ?? WifiHotspotSegment.wifi;
      if (segment != WifiHotspotSegment.wifi) cubit.switchSegment(segment);
      if (segment == WifiHotspotSegment.hotspot &&
          intent != null &&
          Platform.isAndroid) {
        cubit.chooseRole(
          intent == ChannelIntent.create ? HotspotRole.host : HotspotRole.join,
        );
      }
      return cubit;
    },
    child: WifiHotspotPage._(
      initialSegment: initialSegment ?? WifiHotspotSegment.wifi,
      handedCode: handedCode,
    ),
  );

  @override
  State<WifiHotspotPage> createState() => _WifiHotspotPageState();
}

class _WifiHotspotPageState extends State<WifiHotspotPage>
    with WidgetsBindingObserver, SilentPreflightGuard<WifiHotspotPage> {
  bool _navigating = false;

  /// One-shot guard for [_maybeAutoScan] — fires at most once per page
  /// instance, so a scan that comes back invalid (or a manual "scan again")
  /// never re-triggers the camera on its own.
  bool _autoScanTriggered = false;

  /// True only for Tark's combined durable-Room + Wi-Fi payload.
  ///
  /// Merely having [WifiHotspotPage.handedCode] is not enough: old standalone
  /// Wi-Fi QR handoffs use that seam as well and retain their original
  /// peer-heard completion rule.
  bool get _roomHandoff {
    final raw = widget.handedCode;
    if (raw == null) return false;
    return ScannedCode.parse(raw)?.roomInvite != null;
  }

  @override
  TransferMode get preflightMode =>
      widget.initialSegment == WifiHotspotSegment.hotspot
      ? TransferMode.hotspot
      : TransferMode.wifi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Covers the case the listener below can't: an intent of "join" resolves
    // role/joinPhase synchronously inside chooseRole, before this widget ever
    // subscribes to the cubit — so the *first* state it would see is already
    // idle-at-join, not a transition into it. A post-frame callback rather
    // than reading state here directly, because opening the scanner has to
    // push a route, and no route exists to push onto before the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final handed = widget.handedCode;
      if (handed != null) {
        // Spend the one-shot here rather than on the camera: this arrival
        // already has the code, and a submission that comes back invalid must
        // no more re-open the scanner unasked than a bad manual scan does.
        _autoScanTriggered = true;
        unawaited(context.read<WifiHotspotCubit>().submitScannedCode(handed));
        return;
      }
      _maybeAutoScan(context, context.read<WifiHotspotCubit>().state);
    });
  }

  /// Skips the "scan the host's code" tap for whoever already told us,
  /// one screen ago, that scanning is exactly what they're here to do —
  /// whether that arrived as the landing page's "join" intent or a manual
  /// tap on [HotspotRolePicker]'s own join button. Guarded to once per page:
  /// an invalid code or a lost link puts [JoinPhase] back to a state this
  /// would otherwise match again, and re-opening the camera unasked at that
  /// point would be a surprise, not a courtesy.
  void _maybeAutoScan(BuildContext context, HotspotBridgeState state) {
    if (_autoScanTriggered) return;
    if (state.role == HotspotRole.join &&
        state.joinPhase == JoinPhase.idle &&
        state.credentials == null) {
      _autoScanTriggered = true;
      unawaited(openHotspotScanner(context));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-reads the Wi-Fi advice whenever we come back to the front.
  ///
  /// This is the whole reason the "switch Wi-Fi off" note ever goes away: the
  /// user leaves for the system panel, flips the radio, and returns — and a
  /// card still asking for something already done is how advice stops being
  /// read. The floating panel does not always produce a lifecycle change on
  /// every build, which is why the cubit also re-reads on its own.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    context.read<WifiHotspotCubit>().refreshWifiAdvice();
  }

  /// Enters the channel, letting [LinkEstablished] play first.
  ///
  /// **Every** way into the channel comes through here — the peer arriving on
  /// its own, and all three "Enter channel" buttons (plain Wi-Fi, hotspot host,
  /// hotspot join). Previously this navigated on the same frame it was called,
  /// so the success animation was built, laid out and thrown away without ever
  /// being drawn: the transport whose pairing takes the longest was the only
  /// one that never acknowledged it had worked.
  ///
  /// An earlier attempt at this held the beat only for the automatic path, on
  /// the theory that delaying a deliberate tap would read as lag. That was
  /// wrong about the screen it was describing. The button on the join flow
  /// appears at `JoinPhase.joined` — the phone has *just* associated with the
  /// host's AP — and the host flow's appears once the hotspot is up. Tapping
  /// them is the user confirming a connection that already happened, not
  /// requesting a page change, so the acknowledgement belongs on all of them.
  Future<void> _enterChannel(BuildContext context) async {
    if (_navigating) return;
    // Flips the body to the flash immediately; the wait below is what gives it
    // time to be seen.
    setState(() => _navigating = true);
    // The Wi-Fi segment's whole premise is that both phones are already on one
    // network, which means nobody in the Room owns it. Recorded here rather
    // than on arrival, because merely looking at this segment establishes
    // nothing — pressing Enter channel on it does. The hotspot segment writes
    // itself down the moment its access point is up or joined.
    if (context.read<WifiHotspotCubit>().state.segment ==
        WifiHotspotSegment.wifi) {
      context.read<WifiHotspotCubit>().recordSharedNetwork();
    }
    await Future<void>.delayed(LinkEstablished.hold);
    if (!context.mounted) return;
    try {
      // Leave the hotspot up — and the joined network bound — if one was set
      // up; the walkie session runs over it.
      //
      // `ride` says this tap was the end of setting a link up, not a way of
      // reaching a Room: a selected Room would otherwise open its lobby and
      // ask "start?" one screen after the user pressed Enter channel.
      context.goNamed(
        AppRoutes.walkieName,
        queryParameters: const {'ride': 'true'},
      );
    } catch (e) {
      // The flash renders for as long as the flag is set, so a jump that never
      // lands would park the user on "you're in!" with only the back arrow.
      // Drop the flag so another attempt can get through.
      Logger.log('Walkie navigation failed: $e');
      if (mounted) setState(() => _navigating = false);
    }
  }

  /// Back steps out of a chosen side first (host ⇄ join is a decision worth
  /// being able to undo), and only leaves the page once there's no side to
  /// step out of.
  void _back(BuildContext context) {
    final cubit = context.read<WifiHotspotCubit>();

    // A Room one-scan join never exposed or asked for a transport-side choice,
    // so Back must not suddenly reveal the legacy Host / Join picker. Durable
    // membership has already been accepted; cancel only the temporary bridge
    // and return to that Room's lobby.
    if (_roomHandoff) {
      unawaited(cubit.leaveBridge());
      context.goNamed(AppRoutes.walkieName);
      return;
    }

    if (cubit.state.segment == WifiHotspotSegment.hotspot &&
        cubit.state.role != null &&
        Platform.isAndroid) {
      cubit.backToRoleChoice();
      return;
    }
    // Backing out without connecting: tear down whatever was set up (a no-op
    // when nothing was).
    cubit.leaveBridge();
    if (context.canPop()) {
      context.pop();
    } else {
      // Reached directly (quick access landed here) — no stack to pop to.
      context.goNamed(AppRoutes.landingName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return PopScope(
      // The system back gesture would otherwise pop the route without ever
      // running the teardown, leaving an orphaned hotspot up (which then makes
      // the NEXT attempt fail with "tethering already on") or the process still
      // pinned to a network we've walked away from.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(context);
      },
      child: _roomHandoff
          ? _buildRoomHandoffScaffold(context, s)
          : _buildScaffold(context, s),
    );
  }

  /// Normal Room entry deliberately does not expose transfer mechanics.
  ///
  /// While the already-scanned QR is being associated, this is a neutral
  /// connection beat. Only actionable failures fall back to the existing join
  /// flow (Wi-Fi off, Location off, manual join, lost link) so the rider can
  /// recover without learning Host / Join roles or seeing a second QR.
  Widget _buildRoomHandoffScaffold(BuildContext context, AppLocalizations s) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => _back(context),
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<WifiHotspotCubit, HotspotBridgeState>(
          listener: (context, state) {
            if (shouldEnterChannelAfterBridgeUpdate(
                  roomHandoff: true,
                  state: state,
                ) &&
                !_navigating) {
              unawaited(_enterChannel(context));
            }
          },
          builder: (context, state) {
            if (_navigating ||
                state.peerConnected ||
                state.joinPhase == JoinPhase.joined) {
              return HotspotConnectedFlash(label: s.bt_connected);
            }

            if (state.joinPhase == JoinPhase.idle ||
                state.joinPhase == JoinPhase.joining) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const HotspotReachPulse(),
                      const SizedBox(height: 22),
                      Text(
                        s.hotspot_joining,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            // An intervention is actually required. Reuse the battle-tested
            // switch/manual/lost recovery cards, but never show role selection,
            // transport segments or another primary QR in the normal path.
            return HotspotJoinFlow(
              state: state,
              onEnterChannel: () => unawaited(_enterChannel(context)),
            );
          },
        ),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context, AppLocalizations s) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => _back(context),
        ),
        title: Text(
          s.transport_wifi_hotspot,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<WifiHotspotCubit, HotspotBridgeState>(
          listener: (context, state) {
            if (shouldEnterChannelAfterBridgeUpdate(
                  roomHandoff: false,
                  state: state,
                ) &&
                !_navigating) {
              unawaited(_enterChannel(context));
            }
            _maybeAutoScan(context, state);
          },
          builder: (context, state) {
            final showSegments = !_navigating && !state.peerConnected;
            return Column(
              children: [
                if (showSegments)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                    child: HotspotSegmentedControl(
                      segment: state.segment,
                      onChanged: (segment) => context
                          .read<WifiHotspotCubit>()
                          .switchSegment(segment),
                    ),
                  ),
                Expanded(
                  child: _navigating || state.peerConnected
                      ? HotspotConnectedFlash(label: s.bt_connected)
                      : state.segment == WifiHotspotSegment.wifi
                      ? WifiOnlyFlow(
                          onEnterChannel: () =>
                              unawaited(_enterChannel(context)),
                        )
                      : _buildHotspotSegment(context, s, state),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHotspotSegment(
    BuildContext context,
    AppLocalizations s,
    HotspotBridgeState state,
  ) {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return HotspotStatusMessage(
        icon: Icons.wifi_tethering_off_rounded,
        text: s.hotspot_not_supported,
      );
    }
    // iOS is pinned to joining by the cubit (it can't host a local-only AP);
    // Android is asked which end it is, since either phone can be either.
    return switch (state.role) {
      null => HotspotRolePicker(
        onChoose: context.read<WifiHotspotCubit>().chooseRole,
      ),
      HotspotRole.host => HotspotHostFlow(
        state: state,
        onEnterChannel: () => unawaited(_enterChannel(context)),
      ),
      HotspotRole.join => HotspotJoinFlow(
        state: state,
        onEnterChannel: () => unawaited(_enterChannel(context)),
      ),
    };
  }
}
