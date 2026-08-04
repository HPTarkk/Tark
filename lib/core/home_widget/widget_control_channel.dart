import 'dart:async';

import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

/// A control the user pressed on the home-screen widget or smartwatch while a
/// session was live, delivered without bringing the app to the foreground.
enum WidgetControlAction {
  /// MUTE / UNMUTE — handled by the running [WalkieTalkieCubit].
  toggleMute,

  /// Retry the active transport immediately. Smartwatches expose this beside
  /// mute so a rider can heal a degraded room without touching the phone.
  retryConnection,

  /// END — handled at app level (see MyApp), because leaving the channel is
  /// a navigation: routing back to Landing disposes the cubit, and its
  /// close() is what actually tears the session down.
  endSession,
}

/// Inbound half of the native control bridge: Android's widget and Wear OS
/// buttons, plus the iPhone's WatchConnectivity coordinator, calling into Dart.
abstract interface class WidgetControlChannel {
  Stream<WidgetControlAction> get actions;

  void dispose();
}

@LazySingleton(as: WidgetControlChannel)
class WidgetControlChannelImpl implements WidgetControlChannel {
  WidgetControlChannelImpl() {
    // Matches WidgetControlBridge.CHANNEL on Android and the control channel
    // created in AppDelegate on iOS.
    const MethodChannel('tark/widget_control').setMethodCallHandler((call) async {
      final action = switch (call.method) {
        'toggleMute' => WidgetControlAction.toggleMute,
        'retryConnection' => WidgetControlAction.retryConnection,
        'endSession' => WidgetControlAction.endSession,
        _ => null,
      };
      if (action != null && !_controller.isClosed) _controller.add(action);
    });
  }

  final _controller = StreamController<WidgetControlAction>.broadcast();

  @override
  Stream<WidgetControlAction> get actions => _controller.stream;

  @override
  @disposeMethod
  void dispose() => _controller.close();
}
