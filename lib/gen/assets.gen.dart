// dart format width=80

/// GENERATED CODE - DO NOT MODIFY BY HAND
/// *****************************************************
///  FlutterGen
/// *****************************************************

// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: deprecated_member_use,directives_ordering,implicit_dynamic_list_literal,unnecessary_import

import 'package:flutter/widgets.dart';

class $AssetsIconGen {
  const $AssetsIconGen();

  /// File path: assets/icon/icon.png
  AssetGenImage get icon => const AssetGenImage('assets/icon/icon.png');

  /// List of all assets
  List<AssetGenImage> get values => [icon];
}

class $AssetsImageGen {
  const $AssetsImageGen();

  /// File path: assets/image/airpod_bud.png
  AssetGenImage get airpodBud =>
      const AssetGenImage('assets/image/airpod_bud.png');

  /// File path: assets/image/airpod_bud_light.png
  AssetGenImage get airpodBudLight =>
      const AssetGenImage('assets/image/airpod_bud_light.png');

  /// File path: assets/image/airpods_case.png
  AssetGenImage get airpodsCase =>
      const AssetGenImage('assets/image/airpods_case.png');

  /// File path: assets/image/airpods_case_light.png
  AssetGenImage get airpodsCaseLight =>
      const AssetGenImage('assets/image/airpods_case_light.png');

  /// File path: assets/image/helmet.png
  AssetGenImage get helmet => const AssetGenImage('assets/image/helmet.png');

  /// File path: assets/image/helmet_light.png
  AssetGenImage get helmetLight =>
      const AssetGenImage('assets/image/helmet_light.png');

  /// List of all assets
  List<AssetGenImage> get values => [
    airpodBud,
    airpodBudLight,
    airpodsCase,
    airpodsCaseLight,
    helmet,
    helmetLight,
  ];
}

class $AssetsSfxGen {
  const $AssetsSfxGen();

  /// File path: assets/sfx/channel_join.wav
  String get channelJoin => 'assets/sfx/channel_join.wav';

  /// File path: assets/sfx/channel_leave.wav
  String get channelLeave => 'assets/sfx/channel_leave.wav';

  /// File path: assets/sfx/error.wav
  String get error => 'assets/sfx/error.wav';

  /// File path: assets/sfx/link_lost.wav
  String get linkLost => 'assets/sfx/link_lost.wav';

  /// File path: assets/sfx/link_restored.wav
  String get linkRestored => 'assets/sfx/link_restored.wav';

  /// File path: assets/sfx/peer_join.wav
  String get peerJoin => 'assets/sfx/peer_join.wav';

  /// File path: assets/sfx/peer_leave.wav
  String get peerLeave => 'assets/sfx/peer_leave.wav';

  /// File path: assets/sfx/ptt_close.wav
  String get pttClose => 'assets/sfx/ptt_close.wav';

  /// File path: assets/sfx/ptt_open.wav
  String get pttOpen => 'assets/sfx/ptt_open.wav';

  /// File path: assets/sfx/rx_start.wav
  String get rxStart => 'assets/sfx/rx_start.wav';

  /// File path: assets/sfx/toggle.wav
  String get toggle => 'assets/sfx/toggle.wav';

  /// List of all assets
  List<String> get values => [
    channelJoin,
    channelLeave,
    error,
    linkLost,
    linkRestored,
    peerJoin,
    peerLeave,
    pttClose,
    pttOpen,
    rxStart,
    toggle,
  ];
}

class Assets {
  const Assets._();

  static const $AssetsIconGen icon = $AssetsIconGen();
  static const $AssetsImageGen image = $AssetsImageGen();
  static const $AssetsSfxGen sfx = $AssetsSfxGen();
}

class AssetGenImage {
  const AssetGenImage(
    this._assetName, {
    this.size,
    this.flavors = const {},
    this.animation,
  });

  final String _assetName;

  final Size? size;
  final Set<String> flavors;
  final AssetGenImageAnimation? animation;

  Image image({
    Key? key,
    AssetBundle? bundle,
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
    String? semanticLabel,
    bool excludeFromSemantics = false,
    double? scale,
    double? width,
    double? height,
    Color? color,
    Animation<double>? opacity,
    BlendMode? colorBlendMode,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    ImageRepeat repeat = ImageRepeat.noRepeat,
    Rect? centerSlice,
    bool matchTextDirection = false,
    bool gaplessPlayback = true,
    bool isAntiAlias = false,
    String? package,
    FilterQuality filterQuality = FilterQuality.medium,
    int? cacheWidth,
    int? cacheHeight,
  }) {
    return Image.asset(
      _assetName,
      key: key,
      bundle: bundle,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      scale: scale,
      width: width,
      height: height,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      isAntiAlias: isAntiAlias,
      package: package,
      filterQuality: filterQuality,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }

  ImageProvider provider({AssetBundle? bundle, String? package}) {
    return AssetImage(_assetName, bundle: bundle, package: package);
  }

  String get path => _assetName;

  String get keyName => _assetName;
}

class AssetGenImageAnimation {
  const AssetGenImageAnimation({
    required this.isAnimation,
    required this.duration,
    required this.frames,
  });

  final bool isAnimation;
  final Duration duration;
  final int frames;
}
