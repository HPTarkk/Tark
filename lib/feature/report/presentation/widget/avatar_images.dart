import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../../../core/profile/avatar_catalog.dart';

/// Avatar artwork decoded for painting, so the report story can cast each
/// rider as their own face rather than a stock character.
///
/// The member card warms this up when it opens, so by the time someone taps
/// Report the faces are already decoded and the scene never pops them in.
abstract final class AvatarImages {
  /// Plenty for a 76 px face at 3x, and small enough to decode in a frame.
  static const int _decodeSize = 228;

  static final Map<int, Future<ui.Image?>> _cache = {};
  static final Map<int, ui.Image> _ready = {};

  /// The picture for [id] if it is already decoded, so a warmed-up scene
  /// starts with its faces on the very first frame.
  static ui.Image? peek(int? id) {
    final def = AvatarCatalog.byId(id);
    return def == null ? null : _ready[def.id];
  }

  /// The decoded picture for [id], or null when this build has none for it
  /// or it fails to decode (the scene then draws the rider's initial).
  static Future<ui.Image?> load(int? id) {
    final def = AvatarCatalog.byId(id);
    if (def == null) return Future.value();
    return _cache.putIfAbsent(def.id, () => _decode(def.id, def.asset));
  }

  static Future<ui.Image?> _decode(int id, String asset) async {
    try {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        targetWidth: _decodeSize,
        targetHeight: _decodeSize,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return _ready[id] = frame.image;
    } catch (_) {
      return null;
    }
  }
}
