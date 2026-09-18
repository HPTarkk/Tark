import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/channel_gate.dart';

void main() {
  group('ChannelId', () {
    test('open has no code to show', () {
      expect(ChannelId.open.isOpen, isTrue);
      // Not `000000`: a code on screen is an invitation to type it somewhere,
      // and there is nothing here to join.
      expect(ChannelId.open.code, isNull);
    });

    test('a generated channel is never open, whatever the roll', () {
      // Both ends of the range, including the seed that would produce 0 if the
      // generator forgot to offset.
      for (final seed in [0, 1, 7, 99, 12345]) {
        final id = ChannelId.generate(Random(seed));
        expect(id.isOpen, isFalse);
        expect(id.value, greaterThan(0));
        expect(id.value, lessThanOrEqualTo(ChannelId.maxValue));
      }
    });

    test('a code is always six characters, even with leading zeros', () {
      expect(const ChannelId(0xA83F21).code, 'A83F21');
      expect(const ChannelId(1).code, '000001');
      expect(const ChannelId(ChannelId.maxValue).code, 'FFFFFF');
    });

    test('round trips through its own code', () {
      for (final value in [1, 0xA83F21, 0x0000FF, ChannelId.maxValue]) {
        final id = ChannelId(value);
        expect(ChannelId.parse(id.code!)?.value, value);
      }
    });

    group('parsing what a person produces', () {
      test('is forgiving about presentation', () {
        for (final text in [
          'a83f21',
          '  A83F21  ',
          'TARK-A83F21',
          'TARK A83F21',
          'tark:a83f21',
        ]) {
          expect(ChannelId.parse(text)?.value, 0xA83F21, reason: text);
        }
      });

      // Strict about content, on purpose: joining the wrong channel silently is
      // worse than being told to look again.
      test('and strict about content', () {
        for (final text in ['', 'A83F2', 'A83F210', 'GGGGGG', '000000', '-1']) {
          expect(ChannelId.parse(text), isNull, reason: text);
        }
      });
    });

    // A corrupt datagram, or a future format reusing the spare byte, must fail
    // toward hearing people rather than toward excluding them.
    test('an unrepresentable wire value reads as open, not as a channel', () {
      expect(ChannelId.fromWire(0).isOpen, isTrue);
      expect(ChannelId.fromWire(-1).isOpen, isTrue);
      expect(ChannelId.fromWire(0x1000000).isOpen, isTrue);
      expect(ChannelId.fromWire(0xA83F21).value, 0xA83F21);
    });
  });

  group('ChannelGate', () {
    const a = ChannelId(0xAAAAAA);
    const b = ChannelId(0xBBBBBB);

    test('two phones in the same channel hear each other', () {
      expect(const ChannelGate(a).admits(a), isTrue);
    });

    // The one row that drops anything, and the whole reason the feature exists.
    test('two groups on one network do not', () {
      expect(const ChannelGate(a).admits(b), isFalse);
      expect(const ChannelGate(a).excludes(b), isTrue);
    });

    // Everything below is the no-migration property: nothing that predates the
    // channel id may be excluded by it.
    test('an open listener hears everyone', () {
      expect(const ChannelGate(ChannelId.open).admits(a), isTrue);
      expect(const ChannelGate(ChannelId.open).admits(b), isTrue);
      expect(const ChannelGate(ChannelId.open).admits(ChannelId.open), isTrue);
    });

    test('a named listener still hears anyone who named nothing', () {
      expect(const ChannelGate(a).admits(ChannelId.open), isTrue);
    });

    test('zero-setup Wi-Fi is completely unaffected', () {
      // Two phones that both just tapped through: neither has a code, and they
      // must hear each other exactly as they did before this existed.
      const gate = ChannelGate(ChannelId.open);
      expect(gate.admits(ChannelId.open), isTrue);
      expect(gate.excludes(ChannelId.open), isFalse);
    });
  });

  group('ChannelMembership', () {
    test('starts open', () {
      expect(ChannelMembership().current.isOpen, isTrue);
    });

    test('create names a channel, leave gives it up', () {
      final membership = ChannelMembership();
      final created = membership.create();
      expect(membership.current.value, created.value);
      expect(created.isOpen, isFalse);
      membership.leave();
      expect(membership.current.isOpen, isTrue);
    });

    // The host flow and the landing page both call this, and whichever runs
    // first has to win — renumbering would change a code that may already be
    // on the other phone's screen.
    test('createIfNone leaves an existing channel alone', () {
      final membership = ChannelMembership();
      final first = membership.create();
      expect(membership.createIfNone().value, first.value);
    });

    test('createIfNone does create one when there is none', () {
      final membership = ChannelMembership();
      expect(membership.createIfNone().isOpen, isFalse);
    });

    test('announces changes, so a screen showing the code need not poll', () {
      final membership = ChannelMembership();
      final seen = <String?>[];
      final sub = membership.changes.listen((id) => seen.add(id.code));
      final created = membership.create();
      membership.leave();
      return Future<void>.delayed(Duration.zero, () async {
        await sub.cancel();
        expect(seen, [created.code, null]);
      });
    });

    test('setting the same channel twice says nothing', () {
      final membership = ChannelMembership();
      final seen = <ChannelId>[];
      final sub = membership.changes.listen(seen.add);
      membership.join(const ChannelId(0xABCDEF));
      membership.join(const ChannelId(0xABCDEF));
      return Future<void>.delayed(Duration.zero, () async {
        await sub.cancel();
        expect(seen, hasLength(1));
      });
    });
  });

  group('the scanned code', () {
    const creds = HotspotCredentials(
      ssid: 'AndroidShare_1234',
      passphrase: 'hunter2hunter2',
    );

    // The property the whole payload design turns on: a system camera must
    // still see an ordinary Wi-Fi QR and offer its one-tap join.
    test('the channel rides inside a still-valid Wi-Fi payload', () {
      final payload = creds.qrPayload(channel: const ChannelId(0xA83F21));
      expect(payload, startsWith('WIFI:'));
      expect(payload, contains('S:AndroidShare_1234;'));
      expect(payload, contains('P:hunter2hunter2;'));
      expect(payload, contains('TARK1:A83F21;'));
      expect(payload, endsWith(';;'));
    });

    test('and an open channel adds nothing at all', () {
      // Byte-for-byte what shipped before, so a host that names no channel
      // produces a code no scanner can tell from the old one.
      expect(creds.qrPayload(), creds.wifiQrPayload);
      expect(creds.qrPayload(), isNot(contains('TARK1')));
    });

    test('round trips both halves', () {
      final scanned = ScannedCode.parse(
        creds.qrPayload(channel: const ChannelId(0xA83F21)),
      );
      expect(scanned!.credentials, creds);
      expect(scanned.channel.value, 0xA83F21);
    });

    test('a plain Wi-Fi QR still joins, on the open channel', () {
      // A host on an older build, or a code printed on a café wall.
      final scanned = ScannedCode.parse('WIFI:S:CafeGuest;T:WPA;P:latte;;');
      expect(scanned!.credentials!.ssid, 'CafeGuest');
      expect(scanned.channel.isOpen, isTrue);
    });

    test('a channel-only code carries no network', () {
      final scanned = ScannedCode.parse('TARK1:A83F21');
      expect(scanned!.credentials, isNull);
      expect(scanned.channel.value, 0xA83F21);
    });

    // A garbled extension must not cost the user the network half, which is
    // the half they cannot get any other way.
    test(
      'an unreadable channel field falls back to open rather than failing',
      () {
        final scanned = ScannedCode.parse('WIFI:S:X;T:WPA;P:y;TARK1:ZZZ;;');
        expect(scanned!.credentials!.ssid, 'X');
        expect(scanned.channel.isOpen, isTrue);
      },
    );

    test('a future TARK2 field is simply an unknown key', () {
      final scanned = ScannedCode.parse('WIFI:S:X;T:WPA;P:y;TARK2:whatever;;');
      expect(scanned!.credentials!.ssid, 'X');
      expect(scanned.channel.isOpen, isTrue);
    });

    test('anything that is neither is rejected', () {
      for (final text in ['', 'hello', 'https://tarkk.ir', 'TARK1:nope']) {
        expect(ScannedCode.parse(text), isNull, reason: text);
      }
    });

    test('escaped separators in a passphrase still survive', () {
      const awkward = HotspotCredentials(ssid: 'a;b', passphrase: r'p:q\r');
      final scanned = ScannedCode.parse(
        awkward.qrPayload(channel: const ChannelId(0x0000FF)),
      );
      expect(scanned!.credentials, awkward);
      expect(scanned.channel.value, 0xFF);
    });
  });
}
