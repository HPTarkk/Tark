import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/widget/qr_scanner_surface.dart';

/// Fullscreen viewfinder for the host's Wi-Fi QR, on both platforms — the app
/// never sends the user to the system camera, because a code read there can
/// only be acted on in Settings, outside the flow.
///
/// The instrument itself is [QrScannerSurface], shared with Room entry; this
/// page is only the labels and what to do with a hit.
///
/// Pops the raw scanned string, or null if the user backed out.
class HotspotQrScannerPage extends StatelessWidget {
  const HotspotQrScannerPage({super.key});

  /// Opens the scanner and returns what was read (null when dismissed).
  static Future<String?> open(BuildContext context) => Navigator.of(context)
      .push<String>(
        MaterialPageRoute(builder: (_) => const HotspotQrScannerPage()),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return QrScannerSurface(
      title: s.hotspot_scan_host,
      hint: s.hotspot_scan_hint,
      searchingLabel: s.hotspot_scan_searching,
      lockedLabel: s.hotspot_scan_locked,
      cameraDeniedLabel: s.hotspot_scan_camera_denied,
      cameraFailedLabel: s.hotspot_scan_camera_failed,
      openSettingsLabel: s.hotspot_open_settings,
      // Nothing to validate here: the caller owns interpreting the payload, so
      // the frame stays locked and this page leaves with whatever was read.
      onCode: (value) async {
        Navigator.of(context).pop(value);
        return true;
      },
    );
  }
}
