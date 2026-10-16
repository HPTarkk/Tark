import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room_carrier.dart';
import '../../domain/service/room_carrier_promotion_controller.dart';
import 'carrier_status_scope.dart';
import 'manual_join_guide.dart';

/// The Room moving onto a network of its own, told as a scene of its own.
///
/// It used to be a one-line note that flickered above the mic control
/// ("getting the room ready for the road") and was gone before it could be
/// read. Moving every phone across is the one moment in a call when the
/// connection is genuinely changing hands, so it gets the whole screen: the
/// call opens out into the same journey every other connection is told in,
/// the link is drawn being made, it locks, and the scene folds back down into
/// the call it came from.
///
/// The call keeps running underneath, over the network the phones already
/// share, so the scene can be put away ([AppLocalizations.carrier_move_hide])
/// and the move carries on without it. A move that does not happen folds away
/// quietly: nothing was lost, the Room is still on the network it had.
///
/// A move Android keeps turning down is the exception to folding away: from
/// [manualJoinAfterFailures] failed tries on, with the network named, the
/// scene opens on [ManualJoinGuide] instead and stays until the move lands
/// or the person puts it away.
///
/// [child] is the call screen; the scene opens over it.
class CarrierMoveScene extends StatefulWidget {
  const CarrierMoveScene({
    required this.child,
    this.peerName = '',
    this.onOpenWifi,
    super.key,
  });

  final Widget child;

  /// Who the other phone belongs to, for the host's side of the guide.
  final String peerName;

  /// Opens the system Wi-Fi settings. Defaults to the hotspot host's panel.
  final VoidCallback? onOpenWifi;

  @override
  State<CarrierMoveScene> createState() => _CarrierMoveSceneState();
}

class _CarrierMoveSceneState extends State<CarrierMoveScene>
    with SingleTickerProviderStateMixin {
  /// 0 folded into the call, 1 open over it.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
    reverseDuration: const Duration(milliseconds: 620),
  );

  StreamSubscription<RoomCarrierStatus>? _subscription;
  RoomCarrierStatusSource? _source;

  JourneyStage _stage = JourneyStage.linking;
  bool _localIsHost = false;

  /// The generation the person put away, so the same move does not open the
  /// scene again on its next status.
  int? _hiddenGeneration;
  Timer? _fold;

  /// Moves that ended without landing, since the last one that did.
  int _failures = 0;

  /// The network to join by hand, while the scene is showing how.
  HotspotCredentials? _manual;

  /// The person put the guide away; it does not come back by itself.
  bool _manualDismissed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = CarrierStatusScope.of(context);
    if (identical(source, _source)) return;
    _subscription?.cancel();
    _source = source;
    if (source == null) return;
    _subscription = source.statusChanges.listen(_onStatus);
    _onStatus(source.status);
  }

  void _onStatus(RoomCarrierStatus status) {
    if (!mounted) return;
    if (_manual != null && status.network != null) {
      // The guide follows the network actually on offer.
      _manual = status.network;
    }
    if (status.isHandingOver) {
      _fold?.cancel();
      // Trying again behind the guide: keep showing how to join by hand.
      if (_manual != null) {
        setState(() => _localIsHost = status.localIsHost);
        return;
      }
      if (_hiddenGeneration == status.generation) return;
      setState(() {
        _stage = JourneyStage.linking;
        _localIsHost = status.localIsHost;
      });
      _show();
      return;
    }
    final landed =
        status.failure == null &&
        status.durability == RoomCarrierDurability.owned;
    if (landed) {
      _failures = 0;
      _manualDismissed = false;
    } else if (status.failure != null) {
      _failures++;
      final network = status.network;
      if (network != null &&
          !_manualDismissed &&
          _failures >= manualJoinAfterFailures) {
        _fold?.cancel();
        setState(() {
          _manual = network;
          _localIsHost = status.localIsHost;
        });
        _show();
        return;
      }
    }
    if (!_isOpen) return;
    // The move landed: lock the link, hold the beat, fold back into the call.
    if (landed) {
      setState(() {
        _stage = JourneyStage.established;
        _manual = null;
      });
      _fold?.cancel();
      _fold = Timer(
        ConnectionJourney.establishedBeat + const Duration(milliseconds: 500),
        _hide,
      );
      return;
    }
    // It did not happen. Nothing was lost — the call never left the network
    // it was on — so there is nothing to explain; the scene simply goes.
    // Unless it is showing how to join by hand: that stays until it is used.
    if (_manual == null) _hide();
  }

  bool get _isOpen =>
      _open.status == AnimationStatus.forward ||
      _open.status == AnimationStatus.completed;

  void _show() {
    if (_isOpen) return;
    if (AppMotion.reduced(context)) {
      _open.value = 1;
      setState(() {});
    } else {
      _open.forward();
    }
  }

  void _hide() {
    _fold?.cancel();
    if (!mounted || !_isOpen) return;
    // Cleared once the scene has folded, so it does not change under the
    // closing iris.
    if (_manual != null) {
      if (AppMotion.reduced(context)) {
        _open.value = 0;
        setState(() => _manual = null);
      } else {
        _open.reverse().whenComplete(() {
          if (mounted && !_isOpen) setState(() => _manual = null);
        });
      }
      return;
    }
    if (AppMotion.reduced(context)) {
      _open.value = 0;
      setState(() {});
    } else {
      _open.reverse();
    }
  }

  void _putAway() {
    _hiddenGeneration = _source?.status.generation;
    if (_manual != null) _manualDismissed = true;
    _hide();
  }

  /// "I've connected": the scene goes, and the move notices the hotspot as
  /// soon as the host hears this phone on it.
  void _joinedByHand() {
    _hiddenGeneration = _source?.status.generation;
    _hide();
  }

  void _openWifi() {
    final open = widget.onOpenWifi;
    if (open != null) return open();
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<HotspotHost>()) return;
    unawaited(getIt<HotspotHost>().openWifiPanel());
  }

  @override
  void dispose() {
    _fold?.cancel();
    _subscription?.cancel();
    _open.dispose();
    super.dispose();
  }

  Widget _guide(BuildContext context, HotspotCredentials network) {
    final s = context.getString;
    return ManualJoinGuide(
      key: const Key('carrier-move-manual'),
      network: network,
      localIsHost: _localIsHost,
      peerName: widget.peerName,
      failures: _failures,
      actions: [
        if (!_localIsHost) OpenWifiSettingsButton(onOpen: _openWifi),
        OutlinedButton.icon(
          key: const Key('carrier-move-manual-done'),
          onPressed: _joinedByHand,
          icon: const Icon(Icons.check_rounded),
          label: Text(s.manual_join_done),
        ),
        TextButton.icon(
          key: const Key('carrier-move-hide'),
          onPressed: _putAway,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          label: Text(s.carrier_move_hide),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _open,
          builder: (context, scene) {
            final t = _open.value;
            if (t == 0) return const SizedBox.shrink();
            return _Iris(progress: t, child: scene!);
          },
          child: Material(
            key: const Key('carrier-move-scene'),
            color: AppColors.background,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Center(
                  child: _manual != null
                      ? _guide(context, _manual!)
                      : ConnectionJourney(
                          stage: _stage,
                          link: JourneyLink.hotspot,
                          title: _stage == JourneyStage.established
                              ? s.carrier_move_done
                              : s.carrier_move_title,
                          detail: _stage == JourneyStage.established
                              ? null
                              : _localIsHost
                              ? s.carrier_raising_host
                              : s.carrier_raising,
                          actions: [
                            if (_stage != JourneyStage.established)
                              TextButton.icon(
                                key: const Key('carrier-move-hide'),
                                onPressed: _putAway,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 20,
                                ),
                                label: Text(
                                  s.carrier_move_hide,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens the scene out of the middle of the call as a widening circle, the
/// call dimming and drawing back behind it; closing runs it in reverse. Under
/// reduced motion the controller jumps, so this is a cut.
class _Iris extends StatelessWidget {
  const _Iris({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final eased = Curves.easeInOutCubic.transform(progress);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The call recedes rather than being covered.
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.55 * eased),
          ),
        ),
        ClipPath(
          clipper: _IrisClipper(eased),
          child: Opacity(
            opacity: Curves.easeOut.transform(
              ((progress - 0.15) / 0.85).clamp(0.0, 1.0),
            ),
            child: Transform.scale(scale: 0.92 + 0.08 * eased, child: child),
          ),
        ),
        // The rim of the opening, glowing while it moves.
        if (progress < 1)
          IgnorePointer(child: CustomPaint(painter: _IrisRimPainter(eased))),
      ],
    );
  }
}

double _irisRadius(Size size, double t) {
  final full = math.sqrt(
    size.width * size.width / 4 + size.height * size.height / 4,
  );
  return full * t;
}

class _IrisClipper extends CustomClipper<Path> {
  const _IrisClipper(this.t);

  final double t;

  @override
  Path getClip(Size size) => Path()
    ..addOval(
      Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: _irisRadius(size, t),
      ),
    );

  @override
  bool shouldReclip(_IrisClipper old) => old.t != t;
}

class _IrisRimPainter extends CustomPainter {
  const _IrisRimPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final fade = math.sin(t * math.pi);
    canvas.drawCircle(
      size.center(Offset.zero),
      _irisRadius(size, t),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = AppColors.amber.withValues(alpha: 0.8 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  @override
  bool shouldRepaint(_IrisRimPainter old) => old.t != t;
}
