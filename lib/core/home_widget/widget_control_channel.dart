import 'dart:async';

import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

/// A control the user pressed on the home-screen widget while a session was
/// live, delivered without the app ever coming to the foreground.
enum WidgetControlAction {
  /// MUTE / UNMUTE — handled by the running [WalkieTalkieCubit].
  toggleMute,

  /// END — handled at app level (see MyApp), because leaving the channel is
  /// a navigation: routing back to Landing disposes the cubit, and its
  /// close() is what actually tears the session down.
  endSession,
}

/// Inbound half of the widget bridge: Android's widget buttons calling into
/// Dart.
///
/// Android-only by nature — iOS widgets can't reach a backgrounded app, so
/// their controls deep-link instead. On every other platform this simply
/// never emits.
abstract interface class WidgetControlChannel {
  Stream<WidgetControlAction> get actions;

  void dispose();
}

@LazySingleton(as: WidgetControlChannel)
class WidgetControlChannelImpl implements WidgetControlChannel {
  WidgetControlChannelImpl() {
    // Matches WidgetControlBridge.CHANNEL on the Kotlin side.
    const MethodChannel('tark/widget_control').setMethodCallHandler((call) async {
      final action = switch (call.method) {
        'toggleMute' => WidgetControlAction.toggleMute,
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
