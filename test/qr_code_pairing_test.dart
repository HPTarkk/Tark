import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/connect_route.dart';

/// The two QR codes in this app, and what happens when a scanner meets the
/// other one.
///
/// The bridge shows the host's Wi-Fi credentials; the People sheet shows a Room
/// invite. Both are read through the same instrument — `RoomQrJoinPage`'s own
/// doc says it "wears the same viewfinder as the hotspot scanner and the same
/// amber brackets as the invite QR", which is deliberate and is exactly what
/// makes the pairing easy to get wrong. Reported from the field as **"That
/// invite is invalid or expired"** while holding a perfectly good hotspot code.
///
/// This file exists because that failure needs no camera to reproduce: it is
/// entirely a fact about two encoders and two parsers, and it is the half that
/// a widget test cannot pin down.
void main() {
  const host = HotspotCredentials(
    ssid: 'AndroidShare_1234',
    passphrase: 'ridewithme',
  );
  final channel = ChannelId.parse('A83F21')!;

  /// A real Room invite, minted by the build that ships. Borrowed from
  /// `room_direct_join_bundle_test`, where it is pinned as the wire golden.
  const invite =
      'tark-room:AwGrq6urq6urq6urq6urq6urIiIiIiIiIiIiIiIiAwoRGB8mLTQ7QklQV15l'
      'bHN6gYiPlp2kq7K5wMfO1dwLEhkgJy41PENKUVhfZm10e4KJkJeepayzusHIz9bd5B0k'
      'KzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09rh6O_2LzY9REtSWWBnbnV8g4qRmJ-mrbS7'
      'wsnQ197l7PP6AQgPFh0kKzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09rh6IDYyqi9dtLx'
      '5JCGNLKZ95CGNAxNb3JuaW5nIHJpZGUCERERERERERERERERANLx5JCGNBHZh9mF2LHY'
      'p9mHINin2YjZhCIiIiIiIiIiIiIiIgHS8eSQhjQJT3BlbiBzZWF0';

  group('neither parser can read the other one\'s code', () {
    test(
      'the host hotspot QR is not a Room invite, and never looked like one',
      () {
        final payload = host.qrPayload(channel: channel);
        expect(RoomDirectJoinBundle.looksLikeInvite(payload), isFalse);
        expect(
          () => RoomDirectJoinBundle.decode(payload),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('and a Room invite carries no network', () {
      // The mirror, and the reason the room scanner may try one parser and
      // then the other without either of them claiming a code that is not
      // theirs.
      expect(ScannedCode.parse(invite), isNull);
      expect(RoomDirectJoinBundle.looksLikeInvite(invite), isTrue);
    });
  });

  group('so the room scanner can tell three situations apart', () {
    test('a hotspot code is recognised rather than rejected', () {
      final scanned = ScannedCode.parse(host.qrPayload(channel: channel));
      expect(scanned, isNotNull);
      expect(scanned!.credentials?.ssid, host.ssid);
      // The half that justifies *following* the code rather than explaining
      // it. Voice is filtered on the channel, not on Room membership, so a
      // phone that joins this network on this channel is heard — which is
      // what somebody holding a camera up to a code is asking for.
      expect(scanned.channel, channel);
    });

    test('a code that is ours but will not decode still says "invite"', () {
      // Truncated in transit, minted by a future build, genuinely expired:
      // all of them are one `FormatException`, and for all of them "that
      // invite is invalid or expired" is the honest sentence.
      const damaged = 'tark-room:AwGrq6urq6ur';
      expect(RoomDirectJoinBundle.looksLikeInvite(damaged), isTrue);
      expect(
        () => RoomDirectJoinBundle.decode(damaged),
        throwsA(isA<FormatException>()),
      );
    });

    test('and a bus ticket is neither', () {
      for (final junk in const [
        'https://example.com',
        'BEGIN:VCARD',
        '',
        'tark-roomish:AwGr',
      ]) {
        expect(ScannedCode.parse(junk), isNull, reason: junk);
        expect(
          RoomDirectJoinBundle.looksLikeInvite(junk),
          isFalse,
          reason: junk,
        );
      }
    });
  });

  test('a network read by the wrong scanner goes to the joining side', () {
    // Whoever is holding a camera up to somebody else's screen is not the one
    // who made the network, so this is never the host segment.
    final route = ConnectRoute.forScannedNetwork();
    expect(route, startsWith(AppRoutes.wifiHotspotPath));
    expect(route, contains('mode=hotspot'));
    expect(route, contains('intent=join'));
  });
}
