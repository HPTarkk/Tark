import 'package:adtrace_sdk_flutter/adtrace.dart';
import 'package:adtrace_sdk_flutter/adtrace_config.dart';
import 'package:adtrace_sdk_flutter/adtrace_event.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../settings/settings_repository.dart';
import '../utils/logger.dart';
import 'analytics.dart';
import 'analytics_event.dart';

/// Build-time analytics configuration.
abstract final class AnalyticsConfig {
  /// The AdTrace app token, overridable per build:
  ///
  ///     flutter build apk --dart-define=ADTRACE_TOKEN=...
  ///
  /// A fork or a contributor build can pass an empty value to compile the
  /// app with analytics permanently inert, no code changes needed. (The
  /// token isn't a secret — it ships inside every APK regardless — so the
  /// default is committed rather than required at every build.)
  static const appToken = String.fromEnvironment(
    'ADTRACE_TOKEN',
    defaultValue: 'ftph54zfjkrq',
  );

  static bool get isConfigured => appToken.isNotEmpty;

  /// The AdTrace plugin declares Android and iOS only. Calling into it
  /// anywhere else throws MissingPluginException, so the guest web build and
  /// desktop test runs have to short-circuit before the first channel call.
  ///
  /// Uses [defaultTargetPlatform] rather than dart:io's `Platform` on
  /// purpose: dart:io doesn't compile for web at all.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}

/// [Analytics] backed by AdTrace.
///
/// Chosen because it is the only mobile analytics platform that is both free
/// and actually reachable from Iranian networks — Firebase and Sentry are
/// sanction-blocked at the endpoint, and Metrix is now a paid product.
///
/// Opt-out is honoured by *never starting the SDK*, not by starting it and
/// discarding events: an SDK that has been started has already sent a
/// session ping, which for a user who opted out is exactly the thing they
/// opted out of.
@LazySingleton(as: Analytics)
class AdTraceAnalytics implements Analytics {
  AdTraceAnalytics(this._settings);

  final SettingsRepository _settings;

  bool _started = false;

  /// Our own copy of the opt-out state. `AdTrace.setEnabled(false)` is
  /// supposed to stop the SDK tracking on its own, but a privacy switch
  /// shouldn't be a promise a third-party SDK keeps on our behalf — this
  /// gate means a disabled toggle never even reaches the plugin.
  bool _enabled = true;

  @override
  Future<void> start() async {
    if (!AnalyticsConfig.isSupported || !AnalyticsConfig.isConfigured) return;
    _enabled = await _settings.getAnalyticsEnabled();
    if (!_enabled) return;
    _startSdk();
  }

  void _startSdk() {
    if (_started) return;
    // Sandbox in debug keeps development traffic out of the production
    // numbers, so a week of hot reloads can't invent a retention curve.
    final config = AdTraceConfig(
      AnalyticsConfig.appToken,
      kReleaseMode ? AdTraceEnvironment.production : AdTraceEnvironment.sandbox,
    );
    config.logLevel = kReleaseMode
        ? AdTraceLogLevel.suppress
        : AdTraceLogLevel.info;
    AdTrace.start(config);
    _started = true;
    Logger.log('Analytics started (${kReleaseMode ? 'prod' : 'sandbox'})');
  }

  @override
  void track(AnalyticsEvent event) {
    if (!_started || !_enabled) return;
    final adTraceEvent = AdTraceEvent(event.token);
    event.attributes.forEach(adTraceEvent.addEventParameter);
    AdTrace.trackEvent(adTraceEvent);
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!AnalyticsConfig.isSupported || !AnalyticsConfig.isConfigured) return;
    _enabled = enabled;
    if (enabled) {
      // Covers the launch that started with analytics off: there's no SDK
      // running yet to re-enable, so start it now.
      _startSdk();
      AdTrace.setEnabled(true);
    } else if (_started) {
      AdTrace.setEnabled(false);
    }
  }
}
