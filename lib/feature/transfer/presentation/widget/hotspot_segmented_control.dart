import 'package:flutter/material.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/widget/segmented_track.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';

/// Wi-Fi / Hotspot segment switcher at the top of the combined page.
class HotspotSegmentedControl extends StatelessWidget {
  final WifiHotspotSegment segment;
  final ValueChanged<WifiHotspotSegment> onChanged;

  const HotspotSegmentedControl({
    super.key,
    required this.segment,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SegmentedTrack<WifiHotspotSegment>(
      value: segment,
      onChanged: (next) {
        ScreenLog.tab(next.name);
        onChanged(next);
      },
      segments: [
        TrackSegment(
          value: WifiHotspotSegment.wifi,
          icon: Icons.wifi_rounded,
          label: s.transport_wifi,
        ),
        TrackSegment(
          value: WifiHotspotSegment.hotspot,
          icon: Icons.wifi_tethering_rounded,
          label: s.transport_hotspot,
        ),
      ],
    );
  }
}
