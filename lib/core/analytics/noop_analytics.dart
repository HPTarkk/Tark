import 'analytics.dart';
import 'analytics_event.dart';

/// [Analytics] that does nothing.
///
/// Used by the guest web build — whose composition root can't touch the
/// AdTrace plugin, since it declares Android and iOS only — and by tests,
/// which have no business talking to a network SDK.
class NoopAnalytics implements Analytics {
  const NoopAnalytics();

  @override
  Future<void> start() async {}

  @override
  void track(AnalyticsEvent event) {}

  @override
  Future<void> setEnabled(bool enabled) async {}
}
