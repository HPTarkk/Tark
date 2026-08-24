import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidNetworkSelection {
  const AndroidNetworkSelection({
    required this.generation,
    required this.available,
    this.networkHandle,
    this.interfaceName,
    this.isVpn = false,
    this.isWifi = false,
    this.isCellular = false,
  });

  const AndroidNetworkSelection.unavailable({required this.generation})
    : available = false,
      networkHandle = null,
      interfaceName = null,
      isVpn = false,
      isWifi = false,
      isCellular = false;

  final int generation;
  final bool available;
  final int? networkHandle;
  final String? interfaceName;
  final bool isVpn;
  final bool isWifi;
  final bool isCellular;

  factory AndroidNetworkSelection.fromMap(Map<Object?, Object?> map) {
    final generation = (map['generation'] as num?)?.toInt() ?? 0;
    if (map['available'] != true) {
      return AndroidNetworkSelection.unavailable(generation: generation);
    }
    return AndroidNetworkSelection(
      generation: generation,
      available: true,
      networkHandle: (map['networkHandle'] as num?)?.toInt(),
      interfaceName: map['interfaceName'] as String?,
      isVpn: map['isVpn'] == true,
      isWifi: map['isWifi'] == true,
      isCellular: map['isCellular'] == true,
    );
  }

  bool isCurrentComparedWith(AndroidNetworkSelection latest) =>
      generation == latest.generation;
}

abstract final class AndroidNetworkBinding {
  static const MethodChannel _methods = MethodChannel('tark/network_binding');
  static const EventChannel _events = EventChannel(
    'tark/network_binding/events',
  );

  static Future<AndroidNetworkSelection?> current() async {
    if (!Platform.isAndroid) return null;
    try {
      final value = await _methods.invokeMapMethod<Object?, Object?>('current');
      return value == null ? null : AndroidNetworkSelection.fromMap(value);
    } on PlatformException {
      return null;
    }
  }

  static Stream<AndroidNetworkSelection> get changes {
    if (!Platform.isAndroid) return const Stream.empty();
    return _events
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map(
          (event) => AndroidNetworkSelection.fromMap(
            (event as Map).cast<Object?, Object?>(),
          ),
        );
  }
}
