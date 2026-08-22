import '../entity/channel_intent.dart';
import '../entity/transfer_mode.dart';

/// What the device can observe about its own situation, which is all the
/// advisor is allowed to reason from.
///
/// Deliberately facts, not preferences — with one exception, [pinned], which
/// is the escape hatch and is handled by short-circuiting rather than by
/// weighing it against the rest.
class LinkConditions {
  /// This phone is on a Wi-Fi network with a usable local address. The one
  /// condition that changes the answer for both intents at once, because a
  /// shared network is the only case where neither side has to arrange
  /// anything.
  final bool hasWifi;

  /// This device can raise a local-only access point. Android only —
  /// `LocalOnlyHotspot` has no iOS equivalent an app may call.
  final bool canHostHotspot;

  /// This device can scan a code and be told to associate with a network.
  /// Android and iOS both can; desktop and web cannot.
  final bool canJoinHotspot;

  final bool bluetoothSupported;

  /// A transport chosen by hand in Advanced settings, or null for automatic —
  /// which is the default and what almost every install runs.
  final TransferMode? pinned;

  const LinkConditions({
    required this.hasWifi,
    required this.canHostHotspot,
    required this.canJoinHotspot,
    required this.bluetoothSupported,
    this.pinned,
  });
}

/// Why the advisor landed where it did, in terms the landing page can put
/// under a button.
///
/// One reason per *situation*, not per transport: `ownHotspot` and
/// `scanHostCode` are both [TransferMode.hotspot] and describe opposite ends
/// of it, and a single "hotspot" line would be wrong on one of them.
enum ChannelPlanReason {
  /// Both phones are already on one network. Nothing to set up.
  sharedNetwork,

  /// This phone will make the network the other one joins.
  ownHotspot,

  /// The other phone made the network; this one scans its code.
  scanHostCode,

  /// Short-range radio link, no network involved.
  bluetoothLink,

  /// Hosting a browser guest over the LAN.
  guestLink,

  /// Wi-Fi is the transport but there is no network to run it over. The only
  /// reason that reports a dead end rather than a route — see
  /// [ChannelPlan.blocked].
  noNetwork,
}

/// The route a single tap on the landing page will take.
class ChannelPlan {
  final ChannelIntent intent;
  final TransferMode mode;
  final ChannelPlanReason reason;

  /// The transport was chosen by hand rather than observed. Surfaced so the
  /// landing page can say so: a manual pin that stops matching the phone's
  /// situation is otherwise indistinguishable from the app choosing badly.
  final bool pinned;

  const ChannelPlan({
    required this.intent,
    required this.mode,
    required this.reason,
    required this.pinned,
  });

  /// This plan cannot be walked. Only ever true for a pinned Wi-Fi with no
  /// network — automatic never produces it, because it would have moved to
  /// the hotspot or Bluetooth rung instead.
  bool get blocked => reason == ChannelPlanReason.noNetwork;

  /// Guest is a host-only transport: the other end is a browser, not another
  /// copy of this app, so there is nothing on this device for [ChannelIntent
  /// .join] to do. The landing page drops its second action rather than
  /// offering one that leads nowhere.
  bool get hostOnly => mode == TransferMode.guest;

  /// Whether "we might be on different networks" is worth offering as a way
  /// out.
  ///
  /// Exactly when the plan assumed one shared network, which is the single
  /// thing the advisor cannot check: it can see that *this* phone is on a
  /// network, never that the other one is on the same network. Deliberately
  /// still offered for a hand-pinned Wi-Fi, and it is the only route off the
  /// screen when that pin has no network to run over — a pin is a preference,
  /// not a reason to strand someone.
  bool get canFallBackToHotspot => mode == TransferMode.wifi;

  /// The mirror image: whether "actually, we're already together" is worth
  /// offering.
  ///
  /// Automatic reaches for a hotspot first precisely because it *cannot*
  /// check the thing [canFallBackToHotspot] is named for — so the common case
  /// of two phones genuinely on one network (an office, a home Wi-Fi neither
  /// side is about to leave) needs its own way back, the same size as the way
  /// out. Home Wi-Fi is deliberately *not* read as that signal on its own: at
  /// the moment someone opens this screen they are as likely to be about to
  /// walk out the door as to stay, so the plan defaults to the transport that
  /// works either way and lets the person say otherwise.
  bool get canFallBackToWifi => mode == TransferMode.hotspot;
}

/// Picks the transport from what the device can see, so that choosing one is
/// never a prerequisite for making a call.
///
/// **The question this exists to stop asking.** Until now the primary screen
/// asked "Wi-Fi, Bluetooth or Guest?" before it asked anything else, and that
/// is a question about the two phones' surroundings — which the app measures
/// continuously and the user has to guess at. Worse, the answer lived in
/// Settings, so two riders in a field with no Wi-Fi had to leave the main
/// screen before the app would do the only thing that could work there.
///
/// So the axis is inverted: the user answers the one question only they know
/// ("am I starting this, or joining someone?"), and the transport is derived.
/// A hand-picked [LinkConditions.pinned] still wins outright — the derivation
/// is a default, not a policy.
///
/// Pure and synchronous on purpose. Every input is a bool the caller already
/// holds, which keeps the whole decision table testable without a device, and
/// keeps the landing page free of branching that would otherwise be spread
/// across four navigation call sites.
abstract final class TransportAdvisor {
  static ChannelPlan plan(ChannelIntent intent, LinkConditions conditions) {
    final pinned = conditions.pinned;
    if (pinned != null) {
      return ChannelPlan(
        intent: intent,
        mode: pinned,
        reason: _reasonFor(pinned, intent, conditions),
        pinned: true,
      );
    }
    final mode = _automatic(intent, conditions);
    return ChannelPlan(
      intent: intent,
      mode: mode,
      reason: _reasonFor(mode, intent, conditions),
      pinned: false,
    );
  }

  /// The ladder, in the order a person would reason through it.
  ///
  /// The hotspot rung leads, ahead of a network already in hand — and which
  /// each intent reaches by a different capability, since iOS can join an AP
  /// it could never have hosted. That ordering is deliberate, not an
  /// oversight: `hasWifi` only ever says *this* phone can reach a network, and
  /// the one moment this screen matters most is someone standing at home,
  /// on the home Wi-Fi, about to walk out the door with it — the exact
  /// situation where "we're both on a network right now" is the least
  /// trustworthy reading of "we'll still share one in a minute." A hotspot the
  /// two phones make between themselves works whether they stay put or leave,
  /// so it is the default and shared-Wi-Fi is the opt-in (see
  /// [ChannelPlan.canFallBackToWifi]) rather than the other way around.
  /// Bluetooth comes after, needing no network at all but paying for it in
  /// range and bandwidth. Wi-Fi is the floor rather than the ceiling: on a
  /// device that can do none of the above (desktop, web, an iPhone hosting) it
  /// is the only transport left that still binds a socket, and a plan that
  /// goes nowhere reports itself as [ChannelPlan.blocked] rather than
  /// pretending.
  static TransferMode _automatic(ChannelIntent intent, LinkConditions c) {
    final canBridge = switch (intent) {
      ChannelIntent.create => c.canHostHotspot,
      ChannelIntent.join => c.canJoinHotspot,
    };
    if (canBridge) return TransferMode.hotspot;
    if (c.hasWifi) return TransferMode.wifi;
    if (c.bluetoothSupported) return TransferMode.bluetooth;
    return TransferMode.wifi;
  }

  /// Derived from the resolved mode rather than from the branch that chose it,
  /// so a pinned transport gets the same explanation as an automatic one. A
  /// user who pinned Bluetooth is owed the same "over Bluetooth, no network
  /// needed" line as a user the advisor sent there.
  static ChannelPlanReason _reasonFor(
    TransferMode mode,
    ChannelIntent intent,
    LinkConditions c,
  ) => switch (mode) {
    TransferMode.wifi =>
      c.hasWifi ? ChannelPlanReason.sharedNetwork : ChannelPlanReason.noNetwork,
    TransferMode.hotspot => switch (intent) {
      ChannelIntent.create => ChannelPlanReason.ownHotspot,
      ChannelIntent.join => ChannelPlanReason.scanHostCode,
    },
    TransferMode.bluetooth => ChannelPlanReason.bluetoothLink,
    TransferMode.guest => ChannelPlanReason.guestLink,
  };
}
