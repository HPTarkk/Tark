import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

import '../../../core/utils/logger.dart';

/// Opens Tark's page in Cafe Bazaar — the store app when it is installed, the
/// website ([fallback]) when it is not. Backed by `StoreHandler` on Android.
@lazySingleton
class StoreLauncher {
  static const _channel = MethodChannel('tark/store');

  /// Whether anything opened. `false` leaves the prompt up so the user can
  /// try again rather than finding themselves back in the app with nothing
  /// having happened.
  Future<bool> openListing(Uri fallback) async {
    try {
      return await _channel.invokeMethod<bool>('openListing', {
            'url': fallback.toString(),
          }) ??
          false;
    } catch (e) {
      Logger.log('Update: could not open the store — $e');
      return false;
    }
  }
}
