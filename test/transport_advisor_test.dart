import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/channel_intent.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/transport_advisor.dart';

void main() {
  /// A phone: on a network or not, and able to do whatever its OS allows.
  /// Android is the default because it is the only platform that can take
  /// either end of every transport, which makes it the case where a wrong
  /// answer is least likely to be excused by a missing capability.
  LinkConditions android({bool wifi = false, TransferMode? pin}) =>
      LinkConditions(
        hasWifi: wifi,
        canHostHotspot: true,
        canJoinHotspot: true,
        bluetoothSupported: true,
        pinned: pin,
      );

  /// iOS: can join a network it was handed, can never raise one.
  LinkConditions ios({bool wifi = false, TransferMode? pin}) => LinkConditions(
    hasWifi: wifi,
    canHostHotspot: false,
    canJoinHotspot: true,
    bluetoothSupported: true,
    pinned: pin,
  );

  /// Desktop/web: a socket and nothing else.
  LinkConditions bare({bool wifi = false, TransferMode? pin}) =>
      LinkConditions(
        hasWifi: wifi,
        canHostHotspot: false,
        canJoinHotspot: false,
        bluetoothSupported: false,
        pinned: pin,
      );

  group('the automatic ladder', () {
    test('a shared network wins for both intents, and needs no setup', () {
      for (final intent in ChannelIntent.values) {
        final plan = TransportAdvisor.plan(intent, android(wifi: true));
        expect(plan.mode, TransferMode.wifi);
        expect(plan.reason, ChannelPlanReason.sharedNetwork);
        expect(plan.blocked, isFalse);
      }
    });

    test('with no network, Android makes one', () {
      final plan = TransportAdvisor.plan(ChannelIntent.create, android());
      expect(plan.mode, TransferMode.hotspot);
      expect(plan.reason, ChannelPlanReason.ownHotspot);
    });

    // The asymmetry the two capability flags exist for. Same phone, same
    // surroundings, opposite answers — an iPhone can walk onto an access point
    // it could never have raised, so "join" reaches the hotspot rung that
    // "create" falls straight past.
    test('an iPhone can join a hotspot it could not have hosted', () {
      expect(
        TransportAdvisor.plan(ChannelIntent.join, ios()).mode,
        TransferMode.hotspot,
      );
      expect(
        TransportAdvisor.plan(ChannelIntent.create, ios()).mode,
        TransferMode.bluetooth,
      );
    });

    test('the two hotspot ends get opposite instructions', () {
      expect(
        TransportAdvisor.plan(ChannelIntent.create, android()).reason,
        ChannelPlanReason.ownHotspot,
      );
      expect(
        TransportAdvisor.plan(ChannelIntent.join, android()).reason,
        ChannelPlanReason.scanHostCode,
      );
    });

    test('Bluetooth catches what the hotspot rung cannot', () {
      final plan = TransportAdvisor.plan(
        ChannelIntent.create,
        LinkConditions(
          hasWifi: false,
          canHostHotspot: false,
          canJoinHotspot: false,
          bluetoothSupported: true,
        ),
      );
      expect(plan.mode, TransferMode.bluetooth);
      expect(plan.reason, ChannelPlanReason.bluetoothLink);
    });

    // The property that makes the primary screen safe to tap: automatic is
    // only ever allowed to report a dead end on a device that genuinely has
    // one, never as a consequence of its own ordering.
    test('automatic never blocks while any rung is available', () {
      for (final intent in ChannelIntent.values) {
        for (final wifi in [true, false]) {
          expect(TransportAdvisor.plan(intent, android(wifi: wifi)).blocked,
              isFalse);
          expect(
              TransportAdvisor.plan(intent, ios(wifi: wifi)).blocked, isFalse);
        }
      }
    });

    test('a device with no transport at all says so rather than pretending', () {
      final plan = TransportAdvisor.plan(ChannelIntent.create, bare());
      expect(plan.mode, TransferMode.wifi);
      expect(plan.reason, ChannelPlanReason.noNetwork);
      expect(plan.blocked, isTrue);
    });

    test('that same device is fine once it is on a network', () {
      expect(
        TransportAdvisor.plan(ChannelIntent.create, bare(wifi: true)).blocked,
        isFalse,
      );
    });
  });

  group('a hand-pinned transport', () {
    test('short-circuits the ladder outright', () {
      final plan = TransportAdvisor.plan(
        ChannelIntent.create,
        android(wifi: true, pin: TransferMode.bluetooth),
      );
      expect(plan.mode, TransferMode.bluetooth);
      expect(plan.pinned, isTrue);
    });

    test('is honoured even where the ladder would have refused it', () {
      // Bare device, no Bluetooth capability — the pin still wins, because a
      // capability flag is our reading of the device and the pin is the
      // user's, and overruling them silently is how a setting stops meaning
      // anything.
      final plan = TransportAdvisor.plan(
        ChannelIntent.join,
        bare(pin: TransferMode.bluetooth),
      );
      expect(plan.mode, TransferMode.bluetooth);
    });

    // The reason is derived from the resolved mode rather than from the branch
    // that chose it, so a pinned transport is explained the same way an
    // observed one is.
    test('is explained in the same words as an automatic choice', () {
      final auto = TransportAdvisor.plan(ChannelIntent.join, android());
      final pinnedPlan = TransportAdvisor.plan(
        ChannelIntent.join,
        android(pin: TransferMode.hotspot),
      );
      expect(auto.mode, pinnedPlan.mode);
      expect(auto.reason, pinnedPlan.reason);
      expect(auto.pinned, isFalse);
      expect(pinnedPlan.pinned, isTrue);
    });

    test('pinning Wi-Fi with no network is the one blocked plan', () {
      final plan = TransportAdvisor.plan(
        ChannelIntent.create,
        android(pin: TransferMode.wifi),
      );
      expect(plan.blocked, isTrue);
      // …and it must still offer a way off the screen. A pin is a preference,
      // not grounds for stranding someone.
      expect(plan.canFallBackToHotspot, isTrue);
    });
  });

  group('what the plan tells the screen', () {
    test('guest is host-only, so there is no join side to draw', () {
      final plan = TransportAdvisor.plan(
        ChannelIntent.join,
        android(wifi: true, pin: TransferMode.guest),
      );
      expect(plan.hostOnly, isTrue);
      expect(plan.reason, ChannelPlanReason.guestLink);
    });

    test('nothing else is host-only', () {
      for (final mode in TransferMode.values) {
        if (mode == TransferMode.guest) continue;
        expect(
          TransportAdvisor.plan(ChannelIntent.join, android(pin: mode)).hostOnly,
          isFalse,
          reason: '$mode should have a join side',
        );
      }
    });

    // "Not on the same network?" answers the one thing the advisor cannot
    // check — that the *other* phone is on this network — so it belongs
    // exactly where the plan assumed it, and nowhere else.
    test('the different-network way out appears only on a Wi-Fi plan', () {
      expect(
        TransportAdvisor.plan(ChannelIntent.create, android(wifi: true))
            .canFallBackToHotspot,
        isTrue,
      );
      expect(
        TransportAdvisor.plan(ChannelIntent.create, android())
            .canFallBackToHotspot,
        isFalse,
      );
      expect(
        TransportAdvisor.plan(
          ChannelIntent.create,
          android(wifi: true, pin: TransferMode.bluetooth),
        ).canFallBackToHotspot,
        isFalse,
      );
    });

    test('the intent is carried through so the next screen need not ask', () {
      for (final intent in ChannelIntent.values) {
        expect(TransportAdvisor.plan(intent, android()).intent, intent);
      }
    });
  });

  group('ChannelIntent keys', () {
    test('round trip through the query parameter', () {
      for (final intent in ChannelIntent.values) {
        expect(ChannelIntent.fromKey(intent.key), intent);
      }
    });

    test('anything else is no intent, not a default one', () {
      // A guessed side is worse than an unasked question: it starts an access
      // point, or a Bluetooth scan, that nobody requested.
      expect(ChannelIntent.fromKey(null), isNull);
      expect(ChannelIntent.fromKey(''), isNull);
      expect(ChannelIntent.fromKey('host'), isNull);
    });
  });
}
