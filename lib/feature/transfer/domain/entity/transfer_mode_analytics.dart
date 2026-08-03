import '../../../../core/analytics/analytics_event.dart';
import 'transfer_mode.dart';

/// Maps the app's internal transport enum onto the analytics vocabulary.
///
/// The two are kept as separate enums deliberately (see the header of
/// analytics_event.dart): dashboards are a published contract, so adding or
/// renaming a [TransferMode] should force a deliberate decision here rather
/// than silently re-labelling collected data.
extension TransferModeAnalytics on TransferMode {
  AnalyticsTransport get analytics => switch (this) {
    TransferMode.wifi => AnalyticsTransport.wifi,
    TransferMode.bluetooth => AnalyticsTransport.bluetooth,
    // Reported as its own transport even though audio then runs over plain
    // Wi-Fi: what we're measuring here is which *setup path* the user took,
    // and hotspot's setup is the one with a whole extra class of failures.
    TransferMode.hotspot => AnalyticsTransport.hotspot,
    TransferMode.guest => AnalyticsTransport.guest,
  };
}
