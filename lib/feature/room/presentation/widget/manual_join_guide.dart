import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/manual_hotspot_guide.dart';
import '../../../transfer/api/transfer_api.dart';

/// How many times Android may turn a hotspot join down before the move
/// stops asking it and shows the person how to join from Settings.
const manualJoinAfterFailures = 2;

/// What the person chose on the full-screen guide.
enum ManualJoinChoice { connected, bluetooth }

/// [ManualHotspotGuide] worded for this phone's side of the move.
///
/// On the phone that was to join, the steps are its own: Settings, the
/// network, the password, back. On the phone holding the hotspot they are the
/// other person's, with the name and password on this screen to read out or
/// show.
class ManualJoinGuide extends StatelessWidget {
  const ManualJoinGuide({
    required this.network,
    required this.localIsHost,
    required this.peerName,
    required this.failures,
    this.actions = const [],
    super.key,
  });

  final HotspotCredentials network;
  final bool localIsHost;
  final String peerName;
  final int failures;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ManualHotspotGuide(
      title: localIsHost
          ? s.manual_join_title_host(peerName)
          : s.manual_join_title,
      detail: localIsHost
          ? s.manual_join_detail_host(peerName)
          : s.manual_join_detail(failures),
      steps: [
        s.manual_join_step_open,
        s.manual_join_step_pick(network.ssid),
        if (localIsHost)
          s.manual_join_step_password_host
        else
          s.manual_join_step_password,
        if (localIsHost)
          s.manual_join_step_back_host(peerName)
        else
          s.manual_join_step_back,
      ],
      ssid: network.ssid,
      password: network.passphrase,
      networkLabel: s.hotspot_network,
      passwordLabel: s.hotspot_password,
      copiedLabel: s.hotspot_copied,
      actions: actions,
    );
  }
}

/// "Open Wi-Fi settings", for the phone that has to do the joining.
class OpenWifiSettingsButton extends StatelessWidget {
  const OpenWifiSettingsButton({required this.onOpen, super.key});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    key: const Key('manual-join-open-wifi'),
    onPressed: onOpen,
    icon: const Icon(Icons.wifi_rounded),
    label: Text(context.getString.manual_join_open_wifi),
  );
}

/// Opens the guide over whatever is on screen, rising out of it, and answers
/// with what the person picked: null when they went back.
Future<ManualJoinChoice?> showManualJoinGuide(
  BuildContext context, {
  required HotspotCredentials network,
  required bool localIsHost,
  required String peerName,
  required int failures,
  VoidCallback? onOpenWifi,
  bool offerBluetooth = true,
}) {
  return Navigator.of(context).push<ManualJoinChoice>(
    PageRouteBuilder<ManualJoinChoice>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 460),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, _, _) {
        final s = context.getString;
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              key: const Key('manual-join-back'),
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ManualJoinGuide(
                network: network,
                localIsHost: localIsHost,
                peerName: peerName,
                failures: failures,
                actions: [
                  if (!localIsHost && onOpenWifi != null)
                    OpenWifiSettingsButton(onOpen: onOpenWifi),
                  OutlinedButton.icon(
                    key: const Key('manual-join-done'),
                    onPressed: () =>
                        Navigator.of(context).pop(ManualJoinChoice.connected),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(s.manual_join_done),
                  ),
                  if (offerBluetooth)
                    TextButton.icon(
                      key: const Key('manual-join-bluetooth'),
                      onPressed: () =>
                          Navigator.of(context).pop(ManualJoinChoice.bluetooth),
                      icon: const Icon(Icons.bluetooth_rounded, size: 20),
                      label: Text(s.carriermove_use_bluetooth),
                    ),
                ],
              ),
            ),
          ),
        );
      },
      transitionsBuilder: (context, animation, _, child) {
        if (AppMotion.reduced(context)) return child;
        final t = CurvedAnimation(
          parent: animation,
          curve: AppMotion.easeOut,
          reverseCurve: AppMotion.leaving,
        );
        return FadeTransition(
          opacity: t,
          child: AnimatedBuilder(
            animation: t,
            child: child,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, 28 * (1 - t.value)),
              child: Transform.scale(
                scale: 0.96 + 0.04 * t.value,
                child: child,
              ),
            ),
          ),
        );
      },
    ),
  );
}
