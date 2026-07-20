import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';
import '../manager/wifi_hotspot_cubit.dart';
import '../widget/hotspot_host_flow.dart';
import '../widget/hotspot_join_flow.dart';
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

  static Widget buildPage({WifiHotspotSegment? initialSegment}) =>
      BlocProvider<WifiHotspotCubit>(
        create: (_) {
          final cubit = GetIt.instance<WifiHotspotCubit>();
          final segment = initialSegment ?? WifiHotspotSegment.wifi;
          if (segment != WifiHotspotSegment.wifi) cubit.switchSegment(segment);
          return cubit;
        },
        child: WifiHotspotPage._(
          initialSegment: initialSegment ?? WifiHotspotSegment.wifi,
        ),
      );

  @override
  State<WifiHotspotPage> createState() => _WifiHotspotPageState();
}

class _WifiHotspotPageState extends State<WifiHotspotPage> {
  bool _navigating = false;

  void _enterChannel(BuildContext context) {
    if (_navigating) return;
    setState(() => _navigating = true);
    // Leave the hotspot up (if one was created) — the walkie session runs
    // over it.
    context.goNamed(AppRoutes.walkieName);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () {
            // Backing out without connecting: tear the hotspot down (no-op
            // if one was never started).
            context.read<WifiHotspotCubit>().stopHost();
            if (context.canPop()) {
              context.pop();
            } else {
              // Reached directly (quick access landed here) — no stack to
              // pop to.
              context.goNamed(AppRoutes.landingName);
            }
          },
        ),
        title: Text(
          s.transport_wifi_hotspot,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<WifiHotspotCubit, HotspotBridgeState>(
          listener: (context, state) {
            if (state.peerConnected && !_navigating) _enterChannel(context);
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
                          onEnterChannel: () => _enterChannel(context),
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
    if (Platform.isIOS) {
      return HotspotJoinFlow(onEnterChannel: () => _enterChannel(context));
    }
    return HotspotHostFlow(
      state: state,
      onEnterChannel: () => _enterChannel(context),
    );
  }
}
