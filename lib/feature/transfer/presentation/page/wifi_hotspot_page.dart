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
import '../../domain/entity/transfer_mode.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';
import '../manager/wifi_hotspot_cubit.dart';
import '../widget/hotspot_host_flow.dart';
import '../widget/hotspot_join_flow.dart';
import '../widget/hotspot_role_picker.dart';
import '../widget/hotspot_segmented_control.dart';
import '../widget/hotspot_shared_widgets.dart';
import '../widget/hotspot_wifi_only_flow.dart';

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
  const WifiHotspotPage._({required this.initialSegment});

  final WifiHotspotSegment initialSegment;

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
    ),
  );

  @override
  State<WifiHotspotPage> createState() => _WifiHotspotPageState();
}

class _WifiHotspotPageState extends State<WifiHotspotPage>
    with WidgetsBindingObserver, SilentPreflightGuard<WifiHotspotPage> {
  bool _navigating = false;

  @override
  TransferMode get preflightMode => widget.initialSegment == WifiHotspotSegment.hotspot
      ? TransferMode.hotspot
      : TransferMode.wifi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    await Future<void>.delayed(LinkEstablished.hold);
    if (!context.mounted) return;
    try {
      // Leave the hotspot up — and the joined network bound — if one was set
      // up; the walkie session runs over it.
      context.goNamed(AppRoutes.walkieName);
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
      child: _buildScaffold(context, s),
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
            if (state.peerConnected && !_navigating) {
              unawaited(_enterChannel(context));
            }
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
