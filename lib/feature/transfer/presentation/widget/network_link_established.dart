import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../domain/entity/transfer_mode.dart';

/// The moment a verified link lands: the established beat of the app's one
/// [ConnectionJourney] scene, so a shared router, a hotspot and a Bluetooth
/// tether each lock in with their own topology before the channel opens.
class NetworkLinkEstablished extends StatelessWidget {
  const NetworkLinkEstablished({
    required this.hotspot,
    this.bluetooth = false,
    this.roomName,
    this.onComplete,
    super.key,
  });

  final bool hotspot;

  /// A Bluetooth tether rather than an IP network. Wins over [hotspot].
  final bool bluetooth;
  final String? roomName;
  final VoidCallback? onComplete;
  static const sequence = Duration(milliseconds: 1000);
  static const hold = Duration(milliseconds: 1200);

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final link = bluetooth
        ? JourneyLink.bluetooth
        : hotspot
        ? JourneyLink.hotspot
        : JourneyLink.sharedWifi;
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (context, _, _) => KeyedSubtree(
        key: ValueKey(switch (link) {
          JourneyLink.bluetooth => 'bluetooth-link-topology',
          JourneyLink.hotspot => 'hotspot-link-topology',
          JourneyLink.sharedWifi => 'wifi-link-topology',
        }),
        child: ConnectionJourney(
          stage: JourneyStage.established,
          link: link,
          caption: roomName,
          title: switch (link) {
            JourneyLink.bluetooth => s.journey_bluetooth_title,
            JourneyLink.hotspot => s.network_link_hotspot_title,
            JourneyLink.sharedWifi => s.network_link_wifi_title,
          },
          detail: switch (link) {
            JourneyLink.bluetooth => s.journey_bluetooth_detail,
            JourneyLink.hotspot => s.network_link_hotspot_detail,
            JourneyLink.sharedWifi => s.network_link_wifi_detail,
          },
          onEstablished: onComplete,
        ),
      ),
    );
  }
}

/// Shows the verified network's acknowledgement over the live page once.
/// The live subtree keeps its state/socket throughout the beat and reveal.
class NetworkConnectionArrival extends StatefulWidget {
  const NetworkConnectionArrival({
    required this.mode,
    required this.child,
    this.roomName,
    super.key,
  });
  final TransferMode mode;
  final String? roomName;
  final Widget child;
  @override
  State<NetworkConnectionArrival> createState() =>
      _NetworkConnectionArrivalState();
}

class _NetworkConnectionArrivalState extends State<NetworkConnectionArrival> {
  bool _arrived = false;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeSemantics(
        excluding: !_arrived,
        child: IgnorePointer(ignoring: !_arrived, child: widget.child),
      ),
      if (!_arrived)
        Scaffold(
          key: const ValueKey('network-connection-success'),
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: NetworkLinkEstablished(
              hotspot: widget.mode == TransferMode.hotspot,
              bluetooth: widget.mode == TransferMode.bluetooth,
              roomName: widget.roomName,
              onComplete: () {
                if (mounted) setState(() => _arrived = true);
              },
            ),
          ),
        ),
    ],
  );
}

