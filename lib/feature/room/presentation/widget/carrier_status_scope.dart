import 'package:flutter/material.dart';

import '../../domain/service/room_carrier_promotion_controller.dart';

/// Carries the live carrier status down to whatever wants to say something
/// about it.
///
/// An inherited widget rather than a constructor argument because the thing
/// that owns the controller is the composition root above the channel, and the
/// thing that draws the note is several layers inside it — threading a stream
/// through every widget in between would put a transport concern into a dozen
/// constructors that have no other use for one.
///
/// Absent, or present with a null controller, means "no handover machinery
/// here" — a Bluetooth session, a guest link, a device with no signing
/// material. That is not the same as "settled", and callers must render
/// nothing rather than reassurance.
class CarrierStatusScope extends InheritedWidget {
  const CarrierStatusScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final RoomCarrierStatusSource? controller;

  static RoomCarrierStatusSource? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CarrierStatusScope>()
      ?.controller;

  @override
  bool updateShouldNotify(CarrierStatusScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
