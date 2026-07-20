import 'package:injectable/injectable.dart';

import 'sfx_event.dart';
import 'sfx_service.dart';

/// Injectable seam over [Sfx] for cubits, so session logic can be tested
/// with a silent fake. Widgets keep calling the static [Sfx] facade directly
/// — a tap sound in a widget is cosmetic fire-and-forget, same category as
/// `HapticFeedback`.
abstract interface class SfxPlayer {
  void play(SfxEvent event);
}

@LazySingleton(as: SfxPlayer)
class SfxServicePlayer implements SfxPlayer {
  const SfxServicePlayer();

  @override
  void play(SfxEvent event) => Sfx.play(event);
}
